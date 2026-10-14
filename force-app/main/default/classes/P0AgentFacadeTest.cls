@IsTest
private class P0AgentFacadeTest {

    private static final String ROLE = 'P0_Test_Agents';
    private static final String GRANTABLE = 'P0_Test_Grantable';
    private static final String NOT_GRANTABLE = 'P0_Test_Not_Grantable';

    @TestSetup
    static void setup() {
        insert new UserRole(DeveloperName = ROLE, Name = 'P0 Test Agents');
        insert new List<PermissionSet>{
            new PermissionSet(Name = GRANTABLE, Label = 'P0 Test Grantable'),
            new PermissionSet(Name = NOT_GRANTABLE, Label = 'P0 Test Not Grantable')
        };
    }

    private static void configure() {
        P0AgentSettings.settingOverride = new P0_Agent_Setting__mdt(
            Agent_Role__c = ROLE, Gateway_Issuer__c = 'https://gateway.test/');
        P0AgentSettings.grantableOverride = new List<String>{ GRANTABLE };
    }

    private static Map<String, Object> call(String method, String path, Map<String, Object> body) {
        RestRequest req = new RestRequest();
        // Tests do not parse the query string into params.
        req.requestURI = '/services/apexrest/p0/agents' + path.substringBefore('?');
        if (path.contains('?')) {
            for (String pair : path.substringAfter('?').split('&')) {
                req.addParameter(pair.substringBefore('='), pair.substringAfter('='));
            }
        }
        req.httpMethod = method;
        if (body != null) req.requestBody = Blob.valueOf(JSON.serialize(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();
        if (method == 'GET') P0AgentFacade.doGet();
        else if (method == 'PUT') P0AgentFacade.doPut();
        else P0AgentFacade.doPost();
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString());
        result.put('status', RestContext.response.statusCode);
        return result;
    }

    private static Id createAgent(String key) {
        return (Id) call('POST', '', new Map<String, Object>{ 'agentKey' => key }).get('userId');
    }

    private static Set<String> assignedSets(Id userId) {
        Set<String> names = new Set<String>();
        for (PermissionSetAssignment a : [
                SELECT PermissionSet.Name FROM PermissionSetAssignment
                WHERE AssigneeId = :userId AND PermissionSet.IsOwnedByProfile = false]) {
            names.add(a.PermissionSet.Name);
        }
        return names;
    }

    private static Map<String, Object> setGrants(Id agent, List<String> names) {
        return call('PUT', '/' + agent + '/grants', new Map<String, Object>{ 'permissionSets' => names });
    }

    @IsTest
    static void createsAnApiOnlyAgentInTheAgentRole() {
        configure();
        Map<String, Object> result = call('POST', '', new Map<String, Object>{ 'agentKey' => 'abc123' });

        Assert.areEqual(200, result.get('status'));
        Assert.areEqual(true, result.get('created'));
        User agent = [SELECT Username, IsActive, UserRole.DeveloperName, Profile.Name
            FROM User WHERE Id = :(Id) result.get('userId')];
        Assert.isTrue(agent.Username.startsWith('p0-agent-abc123@'));
        Assert.isTrue(agent.IsActive);
        Assert.areEqual(ROLE, agent.UserRole.DeveloperName);
        Assert.areEqual(P0AgentSettings.AGENT_PROFILE, agent.Profile.Name);
    }

    @IsTest
    static void returnsTheSameAgentWhenCalledAgain() {
        configure();
        Id first = createAgent('abc123');
        Map<String, Object> again = call('POST', '', new Map<String, Object>{ 'agentKey' => 'abc123' });

        Assert.areEqual(first, again.get('userId'));
        Assert.areEqual(false, again.get('created'));
    }

    @IsTest
    static void refusesAnInvalidAgentKey() {
        configure();
        Map<String, Object> result = call('POST', '', new Map<String, Object>{ 'agentKey' => 'Not_Valid' });

        Assert.areEqual(400, result.get('status'));
        Assert.areEqual('invalid_agent_key', result.get('error'));
    }

    @IsTest
    static void findsAnAgentByKey() {
        configure();
        Id agent = createAgent('abc123');
        Map<String, Object> result = call('GET', '?agentKey=abc123', null);

        Assert.areEqual(200, result.get('status'));
        Assert.areEqual(agent, result.get('userId'));
        Assert.areEqual(true, result.get('active'));
        Assert.areEqual(404, call('GET', '?agentKey=other', null).get('status'));
    }

    @IsTest
    static void grantsTheSetsAndTheAppAccessSet() {
        configure();
        Id agent = createAgent('abc123');
        Map<String, Object> result = setGrants(agent, new List<String>{ GRANTABLE });

        Assert.areEqual(200, result.get('status'));
        Assert.areEqual(new List<Object>{ GRANTABLE }, result.get('permissionSets'));
        Assert.areEqual(new Set<String>{ GRANTABLE, P0AgentSettings.APP_ACCESS_PERMISSION_SET }, assignedSets(agent));
        Assert.areEqual(200, setGrants(agent, new List<String>{ GRANTABLE }).get('status'));
    }

    @IsTest
    static void removesEveryGrantForAnEmptyList() {
        configure();
        Id agent = createAgent('abc123');
        setGrants(agent, new List<String>{ GRANTABLE });
        Map<String, Object> result = setGrants(agent, new List<String>());

        Assert.areEqual(200, result.get('status'));
        Assert.isTrue(assignedSets(agent).isEmpty());
    }

    @IsTest
    static void refusesASetNotOnTheGrantableList() {
        configure();
        Id agent = createAgent('abc123');
        Map<String, Object> result = setGrants(agent, new List<String>{ GRANTABLE, NOT_GRANTABLE });

        Assert.areEqual(403, result.get('status'));
        Assert.areEqual('permission_set_not_grantable', result.get('error'));
        Assert.isTrue(assignedSets(agent).isEmpty());
    }

    @IsTest
    static void treatsAdminPermissionsAsTooBroad() {
        Assert.isFalse(P0AgentFacade.isTooBroad(new PermissionSet()));
        for (String permission : new List<String>{
                'PermissionsModifyAllData', 'PermissionsViewAllData', 'PermissionsManageUsers',
                'PermissionsAuthorApex', 'PermissionsCustomizeApplication',
                'PermissionsManageProfilesPermissionsets' }) {
            PermissionSet ps = new PermissionSet();
            ps.put(permission, true);
            Assert.isTrue(P0AgentFacade.isTooBroad(ps), permission);
        }
    }

    @IsTest
    static void refusesAUserOutsideTheAgentRole() {
        configure();
        Map<String, Object> result = setGrants(UserInfo.getUserId(), new List<String>{ GRANTABLE });

        Assert.areEqual(404, result.get('status'));
        Assert.areEqual('agent_not_found', result.get('error'));
    }

    @IsTest
    static void retiresAndReactivatesWithNoGrants() {
        configure();
        Id agent = createAgent('abc123');
        setGrants(agent, new List<String>{ GRANTABLE });

        Assert.areEqual(200, call('POST', '/' + agent + '/retire', null).get('status'));
        Assert.isFalse([SELECT IsActive FROM User WHERE Id = :agent].IsActive);
        Assert.isTrue(assignedSets(agent).isEmpty());

        Map<String, Object> again = call('POST', '', new Map<String, Object>{ 'agentKey' => 'abc123' });
        Assert.areEqual(true, again.get('reactivated'));
        Assert.isTrue([SELECT IsActive FROM User WHERE Id = :agent].IsActive);
        Assert.isTrue(assignedSets(agent).isEmpty());
    }

    @IsTest
    static void refusesAGrantToARetiredAgent() {
        configure();
        Id agent = createAgent('abc123');
        call('POST', '/' + agent + '/retire', null);
        Map<String, Object> result = setGrants(agent, new List<String>{ GRANTABLE });

        Assert.areEqual(409, result.get('status'));
    }

    @IsTest
    static void listsTheGrantableSets() {
        configure();
        Map<String, Object> result = call('GET', '/permission-sets', null);

        Assert.areEqual(200, result.get('status'));
        Assert.areEqual(new List<Object>{ GRANTABLE }, result.get('permissionSets'));
    }

    @IsTest
    static void answersAnUnknownRouteWithNotFound() {
        configure();
        Assert.areEqual(404, call('GET', '/unknown', null).get('status'));
    }
}
