# p0-salesforce-agent-access

Salesforce source for P0 agent access. P0 provisions an API-only user for each agent session through `P0AgentFacade`. The P0 agentic gateway exchanges its own token for a session of that user through `P0AgentTokenExchangeHandler`.

- `force-app/` holds what can go in a Salesforce package: the facade, the token-exchange handler, their settings and tests, the grantable-list and settings metadata types, and the `P0_Agent_App_Access` and `P0_Agent_Provisioner` permission sets.
- `org-setup/` holds what Salesforce cannot package, because it is per org: the `P0_Agents` role, the `P0 Agent API Only` profile that agent users get (API access only, so a grant's permission sets are all they can reach), the `P0 Agent` and `P0 Provisioner` external client apps, the token-exchange handler registration, the gateway's remote site, and the `Default` settings record. Deploy-time replacements in its `sfdx-project.json` fill in the values.
- `setup.sh` installs both in an org. `org-values.sh` prints, as JSON, the values that P0 asks for.

## Install in an org

1. Make two users:
   - The provisioner: any user with API access and no admin permissions, e.g. a Salesforce Platform user. P0's connector, in your Google Cloud project, holds this user's app secret, so give it nothing else.
   - The handler's execution user: the user that `P0AgentTokenExchangeHandler` runs as. Today it must be an admin; class access with View Setup, View All Users, API Enabled and Manage Users was not enough, and the minimum is not known yet. Do not use the provisioner.
2. Log in to the org as an admin with the Salesforce CLI (`sf org login web --alias <alias>`). Then run the setup script. It deploys the package, gives the provisioner `P0_Agent_Provisioner`, deploys the org setup, and prints the values that P0 asks for. It is safe to run again. It needs the Salesforce CLI and `jq`.

   ```sh
   git clone https://github.com/p0-security/p0-salesforce-agent-access.git
   cd p0-salesforce-agent-access
   ./setup.sh --target-org <alias> --gateway-issuer https://<gateway host> \
     --provisioner-username <provisioner username> \
     --handler-username <handler execution username> --contact-email <admin email>
   ```

   To print the values again later, run `./org-values.sh <alias>`.

   The package's tests make agent users, so the org needs a free Salesforce Integration licence.
3. Add a `P0 Grantable Permission Set` record for each permission set that agents may request. Agent users have the Salesforce Integration licence, so a set with object permissions must use the `Salesforce API Integration` permission set licence. The facade refuses sets with Modify All Data, View All Data, Manage Users, Author Apex, Customize Application, or Manage Profiles and Permission Sets.
4. Turn on Setup > User Interface > Enable MCP Service, and activate the hosted MCP servers that agents use.
5. In P0, install the org in the Salesforce (AI) integration (`salesforce-ai`). P0 gives you Terraform that deploys its connector to Cloud Run in your Google Cloud project, and a command that stores the `P0 Provisioner` app's consumer secret (from Setup) in your Secret Manager. Then enter the values that the script printed. Then add the Salesforce MCP server with the "Token exchange (RFC 8693)" credential. One server serves every installed org: the server definition reads each grant's org from `generated.tokenExchange`.

A new external client app can take up to 10 minutes to work; until then the token exchange answers `access_denied`.

## Upgrade from a version without the `P0 Agent API Only` profile

The handler and the facade only accept agent users on `P0 Agent API Only`. Agent users made earlier are on `Salesforce API Only System Integrations`, so the facade can no longer retire them or give them grants. Upgrade in this order:

1. In P0, revoke every Salesforce grant, while the old package is still installed. This retires each agent user. Then check that none is active (`sf data query --target-org <alias> -q "SELECT Name FROM User WHERE Username LIKE 'p0-agent-%' AND IsActive = true"` returns no rows). An agent user that is still active when the package changes keeps its permission sets, and P0 can no longer remove them.
2. Run `./setup.sh` again. It deploys the profile, then the package.
3. A session that had a grant before the upgrade keeps its agent key, so its next request finds its old user and fails with `username_taken`. Either start a new session, or move the old users to the new profile once:

   ```sh
   new=$(sf data query --target-org <alias> --json -q "SELECT Id FROM Profile WHERE Name = 'P0 Agent API Only'" | jq -r '.result.records[0].Id')
   sf data query --target-org <alias> --json -q "SELECT Id FROM User WHERE Username LIKE 'p0-agent-%' AND Profile.Name = 'Salesforce API Only System Integrations'" \
     | jq -r '.result.records[].Id' \
     | while read -r id; do
         sf data update record --target-org <alias> --sobject User --record-id "$id" --values "ProfileId=$new"
       done
   ```

## Test

```sh
sf apex run test --target-org <org> --class-names P0AgentFacadeTest \
  --class-names P0AgentTokenExchangeHandlerTest --class-names P0AgentSettingsTest --code-coverage
```

The facade tests create agent users, so the org needs a free Salesforce Integration licence.

## License

LGPL v3. See `LICENSE` and `COPYING`.
