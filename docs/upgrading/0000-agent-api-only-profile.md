## Release date

2026-11-16

# Agent users move to the `P0 Agent API Only` profile

## Who is affected

Every org that installed an earlier version of this package.

## What breaks

The facade and the token-exchange handler only recognise agent users on the `P0 Agent API Only` profile. Agent users made earlier are on `Salesforce API Only System Integrations`. After the upgrade the facade can no longer retire them or change their grants. An agent user that is still active keeps its permission sets, and P0 cannot remove them.

## Steps

1. In P0, revoke every Salesforce grant while the old package is still installed. This retires each agent user.
2. Check that no agent user is active:

   ```sh
   sf data query --target-org <alias> -q "SELECT Name FROM User WHERE Username LIKE 'p0-agent-%' AND IsActive = true"
   ```

   The query must return no rows.
3. Run `./setup.sh` again with the same arguments as the first install. It deploys the profile, then the package.
4. A session that had a grant before the upgrade keeps its agent key. Its next request finds its old, inactive user and fails with `username_taken`. Either start a new session, or move the old users to the new profile once:

   ```sh
   new=$(sf data query --target-org <alias> --json -q "SELECT Id FROM Profile WHERE Name = 'P0 Agent API Only'" | jq -r '.result.records[0].Id // empty')
   if [ -z "$new" ]; then
     echo "The P0 Agent API Only profile is missing. Run ./setup.sh first." >&2
   else
     sf data query --target-org <alias> --json -q "SELECT Id FROM User WHERE Username LIKE 'p0-agent-%' AND Profile.Name = 'Salesforce API Only System Integrations'" \
       | jq -r '.result.records[].Id' \
       | while read -r id; do
           sf data update record --target-org <alias> --sobject User --record-id "$id" --values "ProfileId=$new" \
             || echo "Could not move user $id" >&2
         done
   fi
   ```

## Verify

Request access from an agent in a new session. This query then shows the new user on the new profile:

```sh
sf data query --target-org <alias> -q "SELECT Name, Profile.Name FROM User WHERE Username LIKE 'p0-agent-%' AND IsActive = true"
```

## Roll back

1. Revoke every grant in P0, so that no agent user is active.
2. Redeploy the earlier version of the package. It only recognises agent users on `Salesforce API Only System Integrations`.
3. Move the agent users back. Run the command in step 4 with the two profile names swapped: select the users whose `Profile.Name` is `P0 Agent API Only`, and set `ProfileId` to the id of `Salesforce API Only System Integrations`.
