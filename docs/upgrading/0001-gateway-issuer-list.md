# The org trusts gateways through `P0 Gateway Issuer` records

The Salesforce integration is in beta, so P0 hand-holds these upgrades. This page lists the steps.

## Who is affected

Every org that installed an earlier version of this package.

## What breaks

The handler used to trust the one issuer in the `Gateway Issuer` field of the `Default` settings record. It now trusts only `P0 Gateway Issuer` records, and no longer reads that field. Token exchange fails from the package deploy until `setup.sh` creates a record for each gateway. The script does that right after it deploys the package, so the gap lasts seconds.

Agent keys do not change, so existing sessions and agent users keep working once the records exist.

## Steps

1. Pull the new version and run `./setup.sh` again with the same arguments as the first install, including the same `--gateway-issuer`:

   ```sh
   ./setup.sh --target-org <alias> --gateway-issuer https://<gateway host> \
     --provisioner-username <provisioner username> \
     --handler-username <handler execution username> --contact-email <admin email>
   ```

   The script deploys the package, then creates a `P0 Gateway Issuer` record and a `P0_Gateway_<name>` remote site for that gateway, then continues with the rest of the setup.
2. If the org trusts more than one gateway, run the script once for each one, with that gateway's URL.

## Verify

List the records. Each gateway the org should trust must appear:

```sh
sf data query --target-org <alias> -q "SELECT DeveloperName, Issuer__c FROM P0_Gateway_Issuer__mdt"
```

Then run a token exchange from each gateway.

## Roll back

Redeploy the earlier version, then run its `setup.sh` with the same `--gateway-issuer`. That writes the issuer back to the `Default` record. The earlier code ignores the `P0 Gateway Issuer` records, which stay in the org.
