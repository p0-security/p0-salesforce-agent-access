@IsTest
private class P0AgentTokenExchangeHandlerTest {

    private static final String ROLE = 'P0_Test_Agents';
    private static final String ISSUER = 'https://gateway.test';
    private static final String AUDIENCE = 'https://org.test';

    private static final String USERNAME = P0AgentSettings.agentUsername('abc123');

    private static Map<String, Object> claims(Map<String, Object> overrides) {
        Map<String, Object> claims = new Map<String, Object>{
            'iss' => ISSUER, 'aud' => AUDIENCE, 'sf_agent_key' => 'abc123'
        };
        claims.putAll(overrides);
        return claims;
    }

    @IsTest
    static void makesTheUsernameFromTheAgentKey() {
        Assert.areEqual(USERNAME,
            P0AgentTokenExchangeHandler.usernameFrom(claims(new Map<String, Object>()), ISSUER, AUDIENCE));
    }

    @IsTest
    static void acceptsAnIssuerWithATrailingSlash() {
        Map<String, Object> token = claims(new Map<String, Object>{ 'iss' => ISSUER + '/' });
        Assert.areEqual(USERNAME, P0AgentTokenExchangeHandler.usernameFrom(token, ISSUER, AUDIENCE));
    }

    @IsTest
    static void acceptsTheAudienceInAList() {
        Map<String, Object> token = claims(new Map<String, Object>{
            'aud' => new List<Object>{ 'https://other.test', AUDIENCE }
        });
        Assert.areEqual(USERNAME, P0AgentTokenExchangeHandler.usernameFrom(token, ISSUER, AUDIENCE));
    }

    @IsTest
    static void refusesAnotherIssuerAudienceOrAgentKey() {
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'iss' => 'https://attacker.test' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'aud' => 'https://other.test' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'sf_agent_key' => '' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'sf_agent_key' => 'Admin@other.test' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'sf_agent_key' => 42 }), ISSUER, AUDIENCE));
    }

    @IsTest
    static void decodesTheTokenPayload() {
        String payload = EncodingUtil.base64Encode(Blob.valueOf('{"sf_agent_key":"abc123"}'))
            .replace('+', '-').replace('/', '_').remove('=');
        Map<String, Object> decoded = P0AgentTokenExchangeHandler.claimsOf('e30.' + payload + '.sig');
        Assert.areEqual('abc123', decoded.get('sf_agent_key'));
    }

    @IsTest
    static void refusesATokenThatIsNotAJwt() {
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null, 'token', Auth.OAuth2TokenExchangeType.ACCESS_TOKEN);
        Assert.isFalse(result.isValid());
    }

    @IsTest
    static void refusesAJwtItCannotVerify() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = ROLE, Gateway_Issuer__c = ISSUER);
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null, 'e30.e30.sig', Auth.OAuth2TokenExchangeType.JWT);
        Assert.isFalse(result.isValid());
    }

    @IsTest
    static void mapsOnlyActiveUsersInTheAgentRoleAndProfile() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = ROLE, Gateway_Issuer__c = ISSUER);
        UserRole role = new UserRole(DeveloperName = ROLE, Name = 'P0 Test Agents');
        insert role;
        User agent = new User(
            Username = USERNAME,
            LastName = 'Agent', Alias = 'agent', Email = 'noreply@p0.dev',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'GMT', UserRoleId = role.Id,
            ProfileId = [SELECT Id FROM Profile WHERE Name = :P0AgentSettings.AGENT_PROFILE].Id);
        insert agent;

        P0AgentTokenExchangeHandler handler = new P0AgentTokenExchangeHandler();
        Assert.areEqual(agent.Id, handler.getUserForTokenSubject(
            null, resultFor(agent.Username), false, 'P0_Agent', null).Id);
        Assert.isNull(handler.getUserForTokenSubject(
            null, resultFor(UserInfo.getUserName()), false, 'P0_Agent', null));
    }

    private static Auth.TokenValidationResult resultFor(String username) {
        Auth.UserData userData = new Auth.UserData(
            null, null, null, null, null, null, username, 'en_US', 'P0', null, new Map<String, String>());
        return new Auth.TokenValidationResult(
            true, null, userData, 'token', Auth.OAuth2TokenExchangeType.JWT, 'Invalid P0 token');
    }
}
