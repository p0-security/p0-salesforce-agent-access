# p0-salesforce-agent-access

Salesforce source for P0 agent access. P0 provisions an API-only user for each agent session through `P0AgentFacade`. The P0 agentic gateway exchanges its own token for a session of that user through `P0AgentTokenExchangeHandler`.

- `force-app/` holds what can go in a Salesforce package: the facade, the token-exchange handler, their settings and tests, the grantable-list and settings metadata types, and the `P0_Agent_App_Access` and `P0_Agent_Provisioner` permission sets.
- `org-setup/` holds what Salesforce cannot package, because it is per org: the `P0_Agents` role, the `P0 Agent` and `P0 Provisioner` external client apps, the token-exchange handler registration, the gateway's remote site, and the `Default` settings record. Deploy-time replacements in its `sfdx-project.json` fill in the values.
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

The gateway must allow the `sf_agent_key` claim: add it to `NATIVE_CREDENTIAL_ALLOWED_CLAIMS`.

## Test

```sh
sf apex run test --target-org <org> --class-names P0AgentFacadeTest \
  --class-names P0AgentTokenExchangeHandlerTest --class-names P0AgentSettingsTest --code-coverage
```

The facade tests create agent users, so the org needs a free Salesforce Integration licence.

## License

LGPL v3. See `LICENSE` and `COPYING`.
