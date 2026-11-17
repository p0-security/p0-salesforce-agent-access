@IsTest
private class P0AgentTokenExchangeHandlerTest {

    private static final String ROLE = 'P0_Test_Agents';
    private static final String ISSUER = 'https://gateway.test';
    private static final String ISSUER_TWO = 'https://gateway-two.test';
    private static final String AUDIENCE = 'https://org.test';

    // P0's agentKeyOf test makes the same key from the same issuer and subject.
    private static final String AGENT_KEY = 'b54e2fa2dcc5dace6fa68695';
    private static final String SUBJECT = 'mcps/salesforce/1111111111111111';
    private static final String USERNAME = P0AgentSettings.agentUsername(AGENT_KEY);
    private static final String USERNAME_TWO = P0AgentSettings.agentUsername('7b2bd530e2ffd2f6b71d9515');

    private static void trust(List<String> issuers) {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(Agent_Role__c = ROLE);
        P0AgentSettings.issuersOverride = issuers;
    }

    // The payload is not signed by anyone.
    private static String unsignedToken(Map<String, Object> claims) {
        return 'e30.' + base64Url(JSON.serialize(claims)) + '.sig';
    }

    private static String base64Url(String text) {
        return EncodingUtil.base64Encode(Blob.valueOf(text)).replace('+', '-').replace('/', '_').remove('=');
    }

    private static Map<String, Object> claims(Map<String, Object> overrides) {
        Map<String, Object> claims = new Map<String, Object>{
            'iss' => ISSUER, 'aud' => AUDIENCE, 'sub' => SUBJECT
        };
        claims.putAll(overrides);
        return claims;
    }

    @IsTest
    static void makesTheSameAgentKeyAsP0() {
        Assert.areEqual(AGENT_KEY, P0AgentSettings.agentKey(ISSUER, SUBJECT));
        Assert.areEqual('67547229f9eec3f4b3ec6f7c',
            P0AgentSettings.agentKey(ISSUER, 'mcps/salesforce/2222222222222222'));
    }

    @IsTest
    static void makesTheUsernameFromTheSubject() {
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
    static void refusesAnotherIssuerAudienceOrSubject() {
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'iss' => 'https://attacker.test' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'aud' => 'https://other.test' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'sub' => '' }), ISSUER, AUDIENCE));
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(
            claims(new Map<String, Object>{ 'sub' => 42 }), ISSUER, AUDIENCE));
        Map<String, Object> noSubject = claims(new Map<String, Object>());
        noSubject.remove('sub');
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(noSubject, ISSUER, AUDIENCE));
    }

    @IsTest
    static void anOrgWithOneRecordTrustsOnlyThatIssuer() {
        trust(new List<String>{ ISSUER + '/' });
        Set<String> trusted = P0AgentSettings.gatewayIssuers();

        Assert.areEqual(ISSUER, P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>()), trusted));
        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>{ 'iss' => ISSUER_TWO }), trusted));
    }

    // Same limit as refusesAnUnknownIssuerBeforeAnyJwksFetch: the callout itself is not observed.
    @IsTest
    static void anOrgWithNoRecordsRejectsEveryTokenBeforeAnyJwksFetch() {
        trust(new List<String>());
        Set<String> trusted = P0AgentSettings.gatewayIssuers();

        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(claims(new Map<String, Object>()), trusted));
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null, unsignedToken(claims(new Map<String, Object>())),
            Auth.OAuth2TokenExchangeType.JWT);
        Assert.isFalse(result.isValid());
    }

    @IsTest
    static void doesNotTrustTheDefaultRecordsGatewayIssuer() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = ROLE, Gateway_Issuer__c = ISSUER);
        P0AgentSettings.issuersOverride = new List<String>{ ISSUER_TWO };

        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>()), P0AgentSettings.gatewayIssuers()));
    }

    @IsTest
    static void acceptsASecondIssuerAndMakesItsOwnAgentUsername() {
        trust(new List<String>{ ISSUER, ISSUER_TWO + '/' });
        Set<String> trusted = P0AgentSettings.gatewayIssuers();
        Map<String, Object> second = claims(new Map<String, Object>{ 'iss' => ISSUER_TWO });

        String matched = P0AgentTokenExchangeHandler.trustedIssuer(second, trusted);
        Assert.areEqual(ISSUER_TWO, matched);
        // The same subject is a different agent behind each gateway.
        Assert.areEqual(USERNAME_TWO, P0AgentTokenExchangeHandler.usernameFrom(second, matched, AUDIENCE));
        Assert.areNotEqual(USERNAME,
            P0AgentTokenExchangeHandler.usernameFrom(second, matched, AUDIENCE));
        // A token from one gateway never passes as the other.
        Assert.isNull(P0AgentTokenExchangeHandler.usernameFrom(second, ISSUER, AUDIENCE));
    }

    @IsTest
    static void matchesTheIssuerExactly() {
        Set<String> trusted = new Set<String>{ ISSUER, ISSUER_TWO };
        for (String iss : new List<String>{
            'https://gateway.test.attacker.test', 'https://gateway.tes', 'https://gateway.test/x',
            'https://attacker.test/https://gateway.test', 'https://gateway.test//', 'https://sub.gateway.test',
            'HTTPS://GATEWAY.TEST', 'https://Gateway.test', ' https://gateway.test', 'https://gateway.test ',
            'http://gateway.test', 'gateway.test', 'https://gateway', '', '/'
        }) {
            Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
                claims(new Map<String, Object>{ 'iss' => iss }), trusted), 'iss: ' + iss);
        }
        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>{ 'iss' => 42 }), trusted));
        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>{ 'iss' => new List<Object>{ ISSUER } }), trusted));
        Map<String, Object> noIssuer = claims(new Map<String, Object>());
        noIssuer.remove('iss');
        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(noIssuer, trusted));
    }

    // validateIncomingToken fetches a JWKS only for the issuer that trustedIssuer returns, and an
    // unknown issuer returns before that. This cannot tell that early return from a callout that
    // failed: Test.setMock is ignored by Auth.JWTUtil, and no Auth.HttpCalloutMockUtil method
    // that takes a mock compiles in this org (API v64 and v68). The trustedIssuer asserts pin it.
    @IsTest
    static void refusesAnUnknownIssuerBeforeAnyJwksFetch() {
        trust(new List<String>{ ISSUER, ISSUER_TWO });
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null,
            unsignedToken(claims(new Map<String, Object>{ 'iss' => 'https://attacker.test' })),
            Auth.OAuth2TokenExchangeType.JWT);

        Assert.isFalse(result.isValid());
        Assert.isNull(P0AgentTokenExchangeHandler.trustedIssuer(
            claims(new Map<String, Object>{ 'iss' => 'https://attacker.test' }), P0AgentSettings.gatewayIssuers()));
    }

    @IsTest
    static void decodesTheTokenPayload() {
        String payload = EncodingUtil.base64Encode(Blob.valueOf('{"sub":"mcps/x/1"}'))
            .replace('+', '-').replace('/', '_').remove('=');
        Map<String, Object> decoded = P0AgentTokenExchangeHandler.claimsOf('e30.' + payload + '.sig');
        Assert.areEqual('mcps/x/1', decoded.get('sub'));
    }

    @IsTest
    static void refusesATokenThatIsNotAJwt() {
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null, 'token', Auth.OAuth2TokenExchangeType.ACCESS_TOKEN);
        Assert.isFalse(result.isValid());
    }

    @IsTest
    static void refusesATokenFromATrustedIssuerWhenTheKeyCheckFails() {
        // The trusted iss gets past trustedIssuer, so this reaches validateJWTWithKeysEndpoint.
        // Tests cannot call out, and the token is unsigned, so that call throws: still invalid.
        trust(new List<String>{ ISSUER });
        Auth.TokenValidationResult result = new P0AgentTokenExchangeHandler().validateIncomingToken(
            'P0_Agent', null, unsignedToken(claims(new Map<String, Object>())),
            Auth.OAuth2TokenExchangeType.JWT);
        Assert.isFalse(result.isValid());
    }

    // JSON numbers come back as Integer, Long or Decimal, and a token with no usable exp is refused.
    @IsTest
    static void treatsOnlyAFutureNumericExpAsUnexpired() {
        Long now = 1800000000;

        Assert.isTrue(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => 1800000060 }), now));
        Assert.isTrue(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => 9000000000L }), now));
        Assert.isTrue(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => 1800000060.5 }), now));
        Assert.isFalse(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => 1800000000 }), now), 'exp equal to now is expired');
        Assert.isFalse(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => 1799999999 }), now));
        Assert.isFalse(P0AgentTokenExchangeHandler.unexpired(claims(new Map<String, Object>()), now), 'no exp');
        Assert.isFalse(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => '9999999999' }), now), 'a string exp');
        Assert.isFalse(P0AgentTokenExchangeHandler.unexpired(
            claims(new Map<String, Object>{ 'exp' => null }), now));
    }

    @IsTest
    static void mapsOnlyActiveUsersInTheAgentRoleAndProfile() {
        trust(new List<String>{ ISSUER });
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
