// Exchanges a P0 gateway token for a session of the agent user it names.
// Register it for the agent app with an OauthTokenExchangeHandler (see org-setup).
public without sharing class P0AgentTokenExchangeHandler extends Auth.Oauth2TokenExchangeHandler {

    // The gateway's subject is a per-session hash; its claims template sets this claim.
    @TestVisible private static final String AGENT_KEY_CLAIM = 'sf_agent_key';

    public override Auth.TokenValidationResult validateIncomingToken(
            String appDeveloperName, Auth.IntegratingAppType appType,
            String incomingToken, Auth.OAuth2TokenExchangeType tokenType) {
        if (tokenType != Auth.OAuth2TokenExchangeType.JWT) {
            return new Auth.TokenValidationResult(false);
        }
        try {
            String issuer = P0AgentSettings.gatewayIssuer();
            // Checks the signature against the gateway JWKS, and checks exp.
            Auth.JWTUtil.validateJWTWithKeysEndpoint(incomingToken, issuer + '/.well-known/jwks.json', true);
            String username = usernameFrom(claimsOf(incomingToken), issuer, URL.getOrgDomainUrl().toExternalForm());
            if (username == null) return new Auth.TokenValidationResult(false);
            Auth.UserData userData = new Auth.UserData(
                null, null, null, null, null, null, username, 'en_US', 'P0', null, new Map<String, String>());
            return new Auth.TokenValidationResult(
                true, null, userData, incomingToken, tokenType, 'Invalid P0 token');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'P0 agent token rejected: ' + e.getMessage());
            return new Auth.TokenValidationResult(false);
        }
    }

    // Maps only to active users in the agent role and profile: the facade creates no others.
    public override User getUserForTokenSubject(
            Id networkId, Auth.TokenValidationResult result, Boolean canCreateUser,
            String appDeveloperName, Auth.IntegratingAppType appType) {
        String username = result.userData.username;
        String agentRole = P0AgentSettings.agentRole();
        List<User> users = [
            SELECT Id FROM User
            WHERE Username = :username AND IsActive = true
                AND UserRole.DeveloperName = :agentRole AND Profile.Name = :P0AgentSettings.AGENT_PROFILE
            LIMIT 1
        ];
        return users.isEmpty() ? null : users[0];
    }

    /** @return the agent username, or null when iss, aud or the claim does not match */
    @TestVisible
    private static String usernameFrom(Map<String, Object> claims, String issuer, String audience) {
        Object agentKey = claims.get(AGENT_KEY_CLAIM);
        Object iss = claims.get('iss');
        if (!(iss instanceof String) || ((String) iss).removeEnd('/') != issuer
                || !audienceMatches(claims.get('aud'), audience)
                || !(agentKey instanceof String)) {
            return null;
        }
        return P0AgentSettings.agentUsername((String) agentKey);
    }

    @TestVisible
    private static Map<String, Object> claimsOf(String jwt) {
        String payload = jwt.split('\\.')[1].replace('-', '+').replace('_', '/');
        while (Math.mod(payload.length(), 4) != 0) payload += '=';
        return (Map<String, Object>) JSON.deserializeUntyped(EncodingUtil.base64Decode(payload).toString());
    }

    private static Boolean audienceMatches(Object aud, String audience) {
        if (aud instanceof String) return aud == audience;
        if (aud instanceof List<Object>) return ((List<Object>) aud).contains(audience);
        return false;
    }
}
