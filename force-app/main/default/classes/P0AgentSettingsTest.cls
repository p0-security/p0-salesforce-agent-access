@IsTest
private class P0AgentSettingsTest {

    @IsTest
    static void readsTheRole() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test/');

        Assert.areEqual('P0_Agents', P0AgentSettings.agentRole());
    }

    @IsTest
    static void anOrgWithOnlyTheDefaultRecordTrustsItsIssuerWithoutATrailingSlash() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test/');
        P0AgentSettings.extraIssuersOverride = new List<String>();

        Assert.areEqual(new Set<String>{ 'https://gateway.test' }, P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void trustsTheDefaultIssuerAndTheExtraOnes() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test');
        P0AgentSettings.extraIssuersOverride = new List<String>{
            'https://gateway-two.test/', 'https://gateway.test/'
        };

        Assert.areEqual(new Set<String>{ 'https://gateway.test', 'https://gateway-two.test' },
            P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void ignoresIssuersThatAreNotHttps() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'http://gateway.test');
        P0AgentSettings.extraIssuersOverride = new List<String>{
            'https://', 'ftp://gateway-two.test', 'gateway-three.test', '', null, 'https://gateway-four.test'
        };

        Assert.areEqual(new Set<String>{ 'https://gateway-four.test' }, P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void readsTheExtraIssuersFromCustomMetadata() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test');
        Set<String> issuers = P0AgentSettings.gatewayIssuers();
        Assert.isTrue(issuers.contains('https://gateway.test'));
        for (P0_Gateway_Issuer__mdt row : P0_Gateway_Issuer__mdt.getAll().values()) {
            if (row.Issuer__c.startsWith('https://')) Assert.isTrue(issuers.contains(row.Issuer__c.removeEnd('/')));
        }
    }

    @IsTest
    static void makesADifferentAgentKeyForEachIssuer() {
        String subject = 'mcps/salesforce/1111111111111111';
        // P0 makes the same keys from the same issuer and subject.
        Assert.areEqual('b54e2fa2dcc5dace6fa68695', P0AgentSettings.agentKey('https://gateway.test', subject));
        Assert.areEqual('7b2bd530e2ffd2f6b71d9515', P0AgentSettings.agentKey('https://gateway-two.test', subject));
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
