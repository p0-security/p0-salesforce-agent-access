#!/usr/bin/env bash
# Installs the P0 agent package in a Salesforce org, and prints what the P0
# Salesforce (AI) install asks for. Safe to run again: each step converges.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./setup.sh --target-org <alias> --gateway-issuer <url> \
  --provisioner-username <username> --handler-username <username> \
  --contact-email <email> [--remove-gateway-issuer <url>]...

       ./setup.sh --target-org <alias> --remove-gateway-issuer <url>...

  --target-org            sf CLI alias or username of an admin in the org
  --gateway-issuer        your P0 agentic gateway's URL, e.g. https://gateway.example.com;
                          run again with another URL to trust a second gateway too
  --remove-gateway-issuer stop trusting a gateway: deletes its P0 Gateway Issuer record and its
                          P0_Gateway* remote site, found by URL. Repeat it for several. Without
                          --gateway-issuer this is all the script does, and it needs only --target-org
  --provisioner-username  user that P0 signs in as; API access, no admin rights
  --handler-username      user that the token-exchange handler runs as; must be an admin
  --contact-email         contact email for the two external client apps

Needs the Salesforce CLI (sf) and an admin login to the org:
  sf org login web --alias <alias>
EOF
}

target_org="" gateway_issuer="" provisioner="" handler="" contact=""
remove_issuers=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-org) target_org="$2"; shift 2 ;;
    --gateway-issuer) gateway_issuer="$2"; shift 2 ;;
    --provisioner-username) provisioner="$2"; shift 2 ;;
    --handler-username) handler="$2"; shift 2 ;;
    --contact-email) contact="$2"; shift 2 ;;
    --remove-gateway-issuer) remove_issuers+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Removing needs only the org. Setting up needs everything.
remove_only=false
required=("$target_org")
if [[ -z "$gateway_issuer" && ${#remove_issuers[@]} -gt 0 ]]; then
  remove_only=true
else
  required+=("$gateway_issuer" "$provisioner" "$handler" "$contact")
fi
for value in "${required[@]}"; do
  if [[ -z "$value" ]]; then usage >&2; exit 2; fi
done
if [[ "$remove_only" == false ]]; then
  if [[ "$gateway_issuer" != https://* ]]; then
    echo "--gateway-issuer must be an https URL" >&2
    exit 2
  fi
  gateway_issuer="${gateway_issuer%/}"
  # The issuer goes into XML files and a JWKS URL, so allow only plain URL characters. The
  # handler matches a token's iss exactly, so a mixed-case host would be trusted but never match.
  if [[ ! "$gateway_issuer" =~ ^https://[a-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "--gateway-issuer must be a plain https URL with a lowercase host, e.g. https://gateway.example.com" >&2
    exit 2
  fi
  if [[ "$provisioner" == "$handler" ]]; then
    echo "The provisioner and the handler must be different users" >&2
    exit 2
  fi
fi
command -v sf >/dev/null || {
  echo "Install the Salesforce CLI: https://developer.salesforce.com/tools/salesforcecli" >&2
  exit 1
}
command -v jq >/dev/null || { echo "Install jq" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

# An issuer without any trailing slashes, so one gateway always has one record.
issuer_normalize() {
  local issuer="$1"
  while [[ "$issuer" == */ ]]; do issuer="${issuer%/}"; done
  printf '%s' "$issuer"
}

# The developer name of the P0_Gateway_Issuer record for an issuer. Reuses the name of
# a record that already holds the issuer, so running again changes nothing. Otherwise
# takes the slug, and adds a hash of the issuer when another issuer has that name.
# $1 the issuer, $2 the org's records as JSON: [{"DeveloperName": ..., "Issuer__c": ...}]
issuer_record_name() {
  local issuer existing slug
  issuer="$(issuer_normalize "$1")"
  existing="$(jq -r --arg issuer "$issuer" \
    '[.[] | select(((.Issuer__c // "") | sub("/+$"; "")) == $issuer) | .DeveloperName][0] // empty' <<<"$2")"
  if [[ -n "$existing" ]]; then printf '%s' "$existing"; return; fi
  slug="$(issuer_slug "$issuer")"
  if jq -e --arg name "$slug" 'any(.[]; (.DeveloperName | ascii_downcase) == $name)' <<<"$2" >/dev/null; then
    slug="${slug}_$(issuer_hash "$issuer")"
  fi
  printf '%s' "$slug"
}

query() {
  sf data query --target-org "$target_org" --json --query "$1" | jq -r '.result.records'
}

# Remote sites are tooling objects, not data.
query_tooling() {
  sf data query --target-org "$target_org" --use-tooling-api --json --query "$1" | jq -r '.result.records'
}

# An empty sfdx project in the work directory, for deploys and deletes that bring their own
# metadata. Prints its path.
temp_project() {
  local dir
  dir="$(mktemp -d "$work/project.XXXXXX")"
  mkdir -p "$dir/force-app/main/default/customMetadata" "$dir/force-app/main/default/remoteSiteSettings"
  echo '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"64.0"}' \
    >"$dir/sfdx-project.json"
  printf '%s' "$dir"
}

# Fills a template from org-setup/templates. The name and issuer are safe in sed: a
# name is a slug, and an issuer has passed the URL check, which allows no | or &.
# $1 template, $2 output file, $3 record name, $4 issuer
render_template() {
  sed -e "s|%P0_GATEWAY_NAME%|$3|g" -e "s|%P0_GATEWAY_ISSUER%|$4|g" \
    "$here/org-setup/templates/$1" >"$2"
}

# Stops trusting a gateway. Finds what to delete by the gateway's URL, so the names
# of the files that made it do not matter: the P0_Gateway_Issuer records that hold the
# URL, and the P0_Gateway* remote sites for it. Another remote site for the same URL
# may serve something else, so it stays.
# $1 the issuer
remove_issuer() {
  local issuer records sites line project
  local members=() names=()
  issuer="$(issuer_normalize "$1" | tr 'A-Z' 'a-z')"
  records="$(query "SELECT DeveloperName, Issuer__c FROM P0_Gateway_Issuer__mdt")"
  sites="$(query_tooling "SELECT SiteName, EndpointUrl FROM RemoteProxy")"
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then names+=("$line"); members+=(-m "$line"); fi
  done < <(
    jq -r --arg issuer "$issuer" '
      (.[0] | .[] | select(((.Issuer__c // "") | sub("/+$"; "") | ascii_downcase) == $issuer)
        | "CustomMetadata:P0_Gateway_Issuer." + .DeveloperName),
      (.[1] | .[] | select(((.EndpointUrl // "") | sub("/+$"; "") | ascii_downcase) == $issuer
          and (.SiteName | startswith("P0_Gateway")))
        | "RemoteSiteSetting:" + .SiteName)' <<<"[$records, $sites]"
  )
  if [[ ${#members[@]} -eq 0 ]]; then
    echo "Nothing to remove for $issuer. The org trusts:"
    jq -r '.[] | "  " + (.Issuer__c // "")' <<<"$records"
    return
  fi
  echo "Removing for $issuer:"
  printf '  %s\n' "${names[@]}"
  project="$(temp_project)"
  (cd "$project" && sf project delete source --target-org "$target_org" --wait 30 --no-prompt "${members[@]}")
  jq -r --arg issuer "$issuer" '
    .[] | select(((.EndpointUrl // "") | sub("/+$"; "") | ascii_downcase) == $issuer
        and (.SiteName | startswith("P0_Gateway") | not))
      | "Left alone: remote site " + .SiteName + " also has this URL"' <<<"$sites"
}

# Rejects a removal of the gateway that this run sets up, then normalizes the rest.
removals=()
for url in ${remove_issuers[@]+"${remove_issuers[@]}"}; do
  if [[ "$url" != https://* ]]; then
    echo "--remove-gateway-issuer must be an https URL" >&2
    exit 2
  fi
  url="$(issuer_normalize "$url")"
  if [[ "$url" == "$gateway_issuer" ]]; then
    echo "--gateway-issuer and --remove-gateway-issuer name the same gateway: $url" >&2
    exit 2
  fi
  removals+=("$url")
done

# Warns when no gateway is left, as no agent can then sign in.
warn_if_no_gateway() {
  if [[ "$(query "SELECT DeveloperName FROM P0_Gateway_Issuer__mdt" | jq length)" == "0" ]]; then
    echo "No gateway is trusted now: no agent can sign in until one is added." >&2
  fi
}

if [[ "$remove_only" == true ]]; then
  step "Removing gateways"
  for url in "${removals[@]}"; do remove_issuer "$url"; done
  warn_if_no_gateway
  exit 0
fi

step "Checking the users"
for username in "$provisioner" "$handler"; do
  active="$(query "SELECT IsActive FROM User WHERE Username = '$username'" | jq -r '.[0].IsActive // empty')"
  if [[ "$active" != "true" ]]; then
    echo "No active user '$username' in '$target_org'" >&2
    exit 1
  fi
done

# Every org-setup deploy needs these, including the profile's: the replacements in
# org-setup/sfdx-project.json fail on any file when a variable is unset.
export P0_PROVISIONER_USERNAME="$provisioner" \
  P0_HANDLER_USERNAME="$handler" \
  P0_CONTACT_EMAIL="$contact"

step "Deploying the agent profile"
# The package's tests and its facade look the profile up by name, so it comes first.
(cd "$here/org-setup" && sf project deploy start --target-org "$target_org" --wait 30 -m Profile)

step "Deploying the package source"
# Runs only the package's tests, so tests elsewhere in the org cannot block it.
# The facade tests make agent users, so the org needs a free Salesforce
# Integration licence.
(cd "$here" && sf project deploy start --target-org "$target_org" \
  --source-dir force-app --wait 30 \
  --test-level RunSpecifiedTests \
  --tests P0AgentFacadeTest --tests P0AgentTokenExchangeHandlerTest \
  --tests P0AgentSettingsTest)

step "Trusting the gateway"
# The handler trusts only the P0_Gateway_Issuer records, and Apex may call only a
# remote site, so each gateway gets both. This comes right after the package, so an org
# that already has the handler trusts no gateway for as short a time as possible.
# Metadata file names cannot come from replacements, so fill the templates here.
issuer="$(issuer_normalize "$gateway_issuer")"
records="$(query "SELECT DeveloperName, Issuer__c FROM P0_Gateway_Issuer__mdt")"
name="$(issuer_record_name "$issuer" "$records")"
echo "Gateway $issuer is P0_Gateway_Issuer.$name"
project="$(temp_project)"
metadata="$project/force-app/main/default"
render_template P0_Gateway_Issuer.md-meta.xml.tmpl \
  "$metadata/customMetadata/P0_Gateway_Issuer.$name.md-meta.xml" "$name" "$issuer"
render_template P0_Gateway.remoteSite-meta.xml.tmpl \
  "$metadata/remoteSiteSettings/P0_Gateway_$name.remoteSite-meta.xml" "$name" "$issuer"
(cd "$project" && sf project deploy start --target-org "$target_org" --wait 30 --source-dir force-app)
# Removals come after the add, so the org never trusts nothing in between.
for url in ${removals[@]+"${removals[@]}"}; do remove_issuer "$url"; done

step "Giving the provisioner the P0_Agent_Provisioner permission set"
assigned="$(query "SELECT Id FROM PermissionSetAssignment WHERE Assignee.Username = '$provisioner' AND PermissionSet.Name = 'P0_Agent_Provisioner'" | jq length)"
if [[ "$assigned" == "0" ]]; then
  sf org assign permset --target-org "$target_org" \
    --name P0_Agent_Provisioner --on-behalf-of "$provisioner"
else
  echo "Already assigned"
fi

step "Deploying the org setup"
# The apps must exist before their policies and the handler registration.
(cd "$here/org-setup" && sf project deploy start --target-org "$target_org" --wait 30 \
  -m Role -m CustomMetadata -m ExternalClientApplication \
  -m ExtlClntAppOauthSettings -m ExtlClntAppGlobalOauthSettings)
(cd "$here/org-setup" && sf project deploy start --target-org "$target_org" --wait 30 \
  -m ExtlClntAppOauthConfigurablePolicies -m OauthTokenExchangeHandler)

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
