#!/usr/bin/env bash
# Prints, as JSON, the values that the P0 Salesforce (AI) install asks for.
# Takes the target org as the first argument, or as {"target_org": "..."} on
# stdin, which is how the Terraform external data source calls it.
set -euo pipefail

target_org="${1:-}"
if [[ -z "$target_org" ]]; then
  target_org="$(jq -r '.target_org // empty')"
fi
if [[ -z "$target_org" ]]; then
  echo "Give the target org" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/force-app"
echo '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"64.0"}' \
  >"$work/sfdx-project.json"
(cd "$work" && sf project retrieve start --target-org "$target_org" \
  -m ExtlClntAppGlobalOauthSettings:P0_Agent \
  -m ExtlClntAppGlobalOauthSettings:P0_Provisioner >/dev/null)

consumer_key() {
  sed -n 's:.*<consumerKey>\(.*\)</consumerKey>.*:\1:p' \
    "$work/force-app/main/default/extlClntAppGlobalOauthSets/$1.ecaGlblOauth-meta.xml"
}

instance_url="$(sf org display --target-org "$target_org" --json | jq -r '.result.instanceUrl')"

jq -n \
  --arg full_domain "${instance_url#https://}" \
  --arg provisioner_consumer_key "$(consumer_key P0_Provisioner)" \
  --arg agent_consumer_key "$(consumer_key P0_Agent)" \
  '$ARGS.named'
