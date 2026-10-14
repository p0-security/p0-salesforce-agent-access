@IsTest
private class P0AgentSettingsTest {

    @IsTest
    static void readsTheIssuerWithoutATrailingSlashAndTheRole() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test/');

        Assert.areEqual('https://gateway.test', P0AgentSettings.gatewayIssuer());
        Assert.areEqual('P0_Agents', P0AgentSettings.agentRole());
    }

    @IsTest
    static void readsTheGrantableListFromCustomMetadata() {
        Integer rows = P0_Grantable_Permission_Set__mdt.getAll().size();
        Assert.areEqual(rows, P0AgentSettings.grantable().size());
    }

    @IsTest
    static void readsTheDefaultRecordOrSaysItIsMissing() {
        try {
            Assert.isNotNull(P0AgentSettings.current().Agent_Role__c);
        } catch (P0AgentSettings.MissingSettingException e) {
            Assert.isNull(P0_Agent_Setting__mdt.getInstance('Default'));
        }
    }
}
