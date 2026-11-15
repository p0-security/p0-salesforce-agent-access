#!/usr/bin/env bash
# Installs the P0 agent package in a Salesforce org, and prints what the P0
# Salesforce (AI) install asks for. Safe to run again: each step converges.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./setup.sh --target-org <alias> --gateway-issuer <url> \
  --provisioner-username <username> --handler-username <username> \
  --contact-email <email>

  --target-org            sf CLI alias or username of an admin in the org
  --gateway-issuer        your P0 agentic gateway's URL, e.g. https://gateway.example.com;
                          run again with another URL to trust a second gateway too
  --provisioner-username  user that P0 signs in as; API access, no admin rights
  --handler-username      user that the token-exchange handler runs as; must be an admin
  --contact-email         contact email for the two external client apps

Needs the Salesforce CLI (sf) and an admin login to the org:
  sf org login web --alias <alias>
EOF
}

target_org="" gateway_issuer="" provisioner="" handler="" contact=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-org) target_org="$2"; shift 2 ;;
    --gateway-issuer) gateway_issuer="$2"; shift 2 ;;
    --provisioner-username) provisioner="$2"; shift 2 ;;
    --handler-username) handler="$2"; shift 2 ;;
    --contact-email) contact="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value in "$target_org" "$gateway_issuer" "$provisioner" "$handler" "$contact"; do
  if [[ -z "$value" ]]; then usage >&2; exit 2; fi
done
if [[ "$gateway_issuer" != https://* ]]; then
  echo "--gateway-issuer must be an https URL" >&2
  exit 2
fi
gateway_issuer="${gateway_issuer%/}"
# The issuer goes into XML files and a JWKS URL, so allow only plain URL characters.
if [[ ! "$gateway_issuer" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
  echo "--gateway-issuer must be a plain https URL, e.g. https://gateway.example.com" >&2
  exit 2
fi
if [[ "$provisioner" == "$handler" ]]; then
  echo "The provisioner and the handler must be different users" >&2
  exit 2
fi
command -v sf >/dev/null || {
  echo "Install the Salesforce CLI: https://developer.salesforce.com/tools/salesforcecli" >&2
  exit 1
}
command -v jq >/dev/null || { echo "Install jq" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# A Salesforce developer name for an issuer, from its host and path: lowercase
# letters, digits and single underscores, starting with a letter, at most 20 characters.
# E.g. https://gw.example.com/a -> gw_example_com_a
issuer_slug() {
  local slug
  slug="$(printf '%s' "${1#https://}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  [[ "$slug" == [a-z]* ]] || slug="gw_$slug"
  slug="${slug:0:20}"
  printf '%s' "${slug%_}"
}

issuer_hash() {
  printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8
}

# The developer name of the P0_Gateway_Issuer record for an issuer. Reuses the name of
# a record that already holds the issuer, so running again changes nothing. Otherwise
# takes the slug, and adds a hash of the issuer when another issuer has that name.
# $1 the issuer, $2 the org's records as JSON: [{"DeveloperName": ..., "Issuer__c": ...}]
issuer_record_name() {
  local existing slug
  existing="$(jq -r --arg issuer "$1" \
    '[.[] | select(((.Issuer__c // "") | rtrimstr("/")) == $issuer) | .DeveloperName][0] // empty' <<<"$2")"
  if [[ -n "$existing" ]]; then printf '%s' "$existing"; return; fi
  slug="$(issuer_slug "$1")"
  if jq -e --arg name "$slug" 'any(.[]; (.DeveloperName | ascii_downcase) == $name)' <<<"$2" >/dev/null; then
    slug="${slug}_$(issuer_hash "$1")"
  fi
  printf '%s' "$slug"
}

query() {
  sf data query --target-org "$target_org" --json --query "$1" | jq -r '.result.records'
}

step "Checking the users"
for username in "$provisioner" "$handler"; do
  active="$(query "SELECT IsActive FROM User WHERE Username = '$username'" | jq -r '.[0].IsActive // empty')"
  if [[ "$active" != "true" ]]; then
    echo "No active user '$username' in '$target_org'" >&2
    exit 1
  fi
done

step "Deploying the package source"
# Runs only the package's tests, so tests elsewhere in the org cannot block it.
# The facade tests make agent users, so the org needs a free Salesforce
# Integration licence.
(cd "$here" && sf project deploy start --target-org "$target_org" \
  --source-dir force-app --wait 30 \
  --test-level RunSpecifiedTests \
  --tests P0AgentFacadeTest --tests P0AgentTokenExchangeHandlerTest \
  --tests P0AgentSettingsTest)

step "Giving the provisioner the P0_Agent_Provisioner permission set"
assigned="$(query "SELECT Id FROM PermissionSetAssignment WHERE Assignee.Username = '$provisioner' AND PermissionSet.Name = 'P0_Agent_Provisioner'" | jq length)"
if [[ "$assigned" == "0" ]]; then
  sf org assign permset --target-org "$target_org" \
    --name P0_Agent_Provisioner --on-behalf-of "$provisioner"
else
  echo "Already assigned"
fi

step "Deploying the org setup"
# The Default record and the P0_Gateway remote site hold the first gateway: the one
# an earlier run set, or this one in a new org. Another gateway gets a record and a
# remote site of its own, so running again with a new issuer adds to the first.
default_issuer="$(query "SELECT Gateway_Issuer__c FROM P0_Agent_Setting__mdt WHERE DeveloperName = 'Default'" \
  | jq -r '.[0].Gateway_Issuer__c // empty')"
default_issuer="${default_issuer%/}"
if [[ -z "$default_issuer" ]]; then default_issuer="$gateway_issuer"; fi
export P0_GATEWAY_ISSUER="$default_issuer" \
  P0_PROVISIONER_USERNAME="$provisioner" \
  P0_HANDLER_USERNAME="$handler" \
  P0_CONTACT_EMAIL="$contact"
# The apps must exist before their policies and the handler registration.
(cd "$here/org-setup" && sf project deploy start --target-org "$target_org" --wait 30 \
  -m Role -m CustomMetadata -m RemoteSiteSetting -m ExternalClientApplication \
  -m ExtlClntAppOauthSettings -m ExtlClntAppGlobalOauthSettings)
(cd "$here/org-setup" && sf project deploy start --target-org "$target_org" --wait 30 \
  -m ExtlClntAppOauthConfigurablePolicies -m OauthTokenExchangeHandler)

if [[ "$gateway_issuer" == "$default_issuer" ]]; then
  echo "Gateway $gateway_issuer is the org's first gateway"
else
  # Metadata file names cannot come from replacements, so render these files here.
  records="$(query "SELECT DeveloperName, Issuer__c FROM P0_Gateway_Issuer__mdt")"
  name="$(issuer_record_name "$gateway_issuer" "$records")"
  echo "Adding gateway $gateway_issuer as P0_Gateway_Issuer.$name"
  extra="$(mktemp -d)"
  trap 'rm -rf "$extra"' EXIT
  mkdir -p "$extra/force-app/main/default/customMetadata" "$extra/force-app/main/default/remoteSiteSettings"
  echo '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"64.0"}' \
    >"$extra/sfdx-project.json"
  cat >"$extra/force-app/main/default/customMetadata/P0_Gateway_Issuer.$name.md-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>$name</label>
    <protected>false</protected>
    <values>
        <field>Issuer__c</field>
        <value xsi:type="xsd:string">$gateway_issuer</value>
    </values>
</CustomMetadata>
XML
  cat >"$extra/force-app/main/default/remoteSiteSettings/P0_Gateway_$name.remoteSite-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A P0 agentic gateway, for its JWKS</description>
    <disableProtocolSecurity>false</disableProtocolSecurity>
    <isActive>true</isActive>
    <url>$gateway_issuer</url>
</RemoteSiteSetting>
XML
  (cd "$extra" && sf project deploy start --target-org "$target_org" --wait 30 --source-dir force-app)
fi

step "Getting the apps' consumer keys"
values="$("$here/org-values.sh" "$target_org")"
value() { jq -r ".$1" <<<"$values"; }

cat <<EOF

Done. Install the org in P0's Salesforce (AI) integration with:

  Full domain                $(value full_domain)
  Provisioner consumer key   $(value provisioner_consumer_key)
  Provisioner consumer secret  Setup > External Client App Manager > P0 Provisioner >
                               Settings > OAuth Settings > Consumer Key and Secret
  Agent app consumer key     $(value agent_consumer_key)

Before agents can use it:
  1. Add a P0 Grantable Permission Set record (Setup > Custom Metadata Types)
     for each permission set that agents may request.
  2. Turn on Setup > User Interface > Enable MCP Service, and activate the
     hosted MCP servers that agents use.
  3. New external client apps can take up to 10 minutes to work.
EOF
