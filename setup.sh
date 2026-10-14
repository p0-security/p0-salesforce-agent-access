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
  --gateway-issuer        your P0 agentic gateway's URL, e.g. https://gateway.example.com
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
export P0_GATEWAY_ISSUER="$gateway_issuer" \
  P0_PROVISIONER_USERNAME="$provisioner" \
  P0_HANDLER_USERNAME="$handler" \
  P0_CONTACT_EMAIL="$contact"
# The Salesforce CLI does not apply replacements under a path with a dot
# directory, such as .terraform/modules. Deploy from a copy.
org_setup="$(mktemp -d)"
trap 'rm -rf "$org_setup"' EXIT
cp -R "$here/org-setup/." "$org_setup"
# The apps must exist before their policies and the handler registration.
(cd "$org_setup" && sf project deploy start --target-org "$target_org" --wait 30 \
  -m Role -m CustomMetadata -m RemoteSiteSetting -m ExternalClientApplication \
  -m ExtlClntAppOauthSettings -m ExtlClntAppGlobalOauthSettings)
(cd "$org_setup" && sf project deploy start --target-org "$target_org" --wait 30 \
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
