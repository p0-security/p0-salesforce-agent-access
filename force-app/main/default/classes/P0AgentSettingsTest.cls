@IsTest
private class P0AgentSettingsTest {

    @IsTest
    static void readsTheRole() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents');

        Assert.areEqual('P0_Agents', P0AgentSettings.agentRole());
    }

    @IsTest
    static void trustsTheIssuersOfTheRecordsWithoutATrailingSlash() {
        P0AgentSettings.issuersOverride = new List<String>{
            'https://gateway.test/', 'https://gateway-two.test', 'https://gateway.test'
        };

        Assert.areEqual(new Set<String>{ 'https://gateway.test', 'https://gateway-two.test' },
            P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void anOrgWithNoRecordsTrustsNoIssuer() {
        P0AgentSettings.issuersOverride = new List<String>();

        Assert.isTrue(P0AgentSettings.gatewayIssuers().isEmpty());
    }

    @IsTest
    static void ignoresTheDefaultRecordsGatewayIssuer() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = 'P0_Agents', Gateway_Issuer__c = 'https://gateway.test');
        P0AgentSettings.issuersOverride = new List<String>{ 'https://gateway-two.test' };

        Assert.areEqual(new Set<String>{ 'https://gateway-two.test' }, P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void ignoresIssuersThatAreNotHttps() {
        P0AgentSettings.issuersOverride = new List<String>{
            'http://gateway.test', 'https://', 'ftp://gateway-two.test', 'gateway-three.test', '', null,
            'https://gateway-four.test'
        };

        Assert.areEqual(new Set<String>{ 'https://gateway-four.test' }, P0AgentSettings.gatewayIssuers());
    }

    @IsTest
    static void readsTheIssuersFromCustomMetadata() {
        Set<String> issuers = P0AgentSettings.gatewayIssuers();
        for (P0_Gateway_Issuer__mdt row : P0_Gateway_Issuer__mdt.getAll().values()) {
            if (row.Issuer__c.startsWith('https://')) Assert.isTrue(issuers.contains(row.Issuer__c.removeEnd('/')));
        }
        Assert.isTrue(issuers.size() <= P0_Gateway_Issuer__mdt.getAll().size());
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
