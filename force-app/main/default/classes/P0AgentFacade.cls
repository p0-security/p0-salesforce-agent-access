// Runs in system mode: the caller needs access to this class only, not Manage Users.
@RestResource(urlMapping='/p0/agents/*')
global without sharing class P0AgentFacade {

    private static final String AGENT_PROFILE = P0AgentSettings.AGENT_PROFILE;
    private static final String APP_ACCESS_PERMISSION_SET = P0AgentSettings.APP_ACCESS_PERMISSION_SET;
    private static final String AGENT_EMAIL = 'noreply@p0.dev';
    private static final String PATH_PREFIX = '/p0/agents';
    // PermissionSetLicense ids start with this key prefix; UserLicense ids do not.
    private static final String PERMISSION_SET_LICENSE_PREFIX = '0PL';
    private static final Pattern USER_ID = Pattern.compile('005[A-Za-z0-9]{12}([A-Za-z0-9]{3})?');

    @HttpGet
    global static void doGet() {
        route('GET');
    }

    @HttpPost
    global static void doPost() {
        route('POST');
    }

    @HttpPut
    global static void doPut() {
        route('PUT');
    }

    private static void route(String method) {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Savepoint sp = Database.setSavepoint();
        try {
            List<String> path = pathSegments();
            Object body;
            if (method == 'GET' && path.size() == 1 && path[0] == 'permission-sets') {
                body = listGrantable();
            } else if (method == 'GET' && path.isEmpty()) {
                body = findAgent(RestContext.request.params.get('agentKey'));
            } else if (method == 'POST' && path.isEmpty()) {
                body = upsertAgent(requestBody());
            } else if (method == 'PUT' && path.size() == 2 && path[1] == 'grants') {
                body = setGrants(path[0], requestBody());
            } else if (method == 'POST' && path.size() == 2 && path[1] == 'retire') {
                body = retire(path[0]);
            } else {
                throw fail(404, 'not_found');
            }
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(body));
        } catch (FacadeException e) {
            Database.rollback(sp);
            res.statusCode = e.status;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'error' => e.getMessage() }));
        }
    }

    private static Map<String, Object> upsertAgent(Map<String, Object> body) {
        String agentRole = P0AgentSettings.agentRole();
        String key = requiredString(body, 'agentKey');
        String username = P0AgentSettings.agentUsername(key);
        if (username == null) throw fail(400, 'invalid_agent_key');

        List<User> existing = [
            SELECT Id, IsActive, UserRole.DeveloperName, Profile.Name
            FROM User WHERE Username = :username LIMIT 1
        ];
        if (!existing.isEmpty()) {
            User u = existing[0];
            if (u.UserRole.DeveloperName != agentRole || u.Profile.Name != AGENT_PROFILE) {
                throw fail(409, 'username_taken');
            }
            Boolean reactivated = !u.IsActive;
            if (reactivated) update new User(Id = u.Id, IsActive = true);
            return agentResult(u.Id, username, false, reactivated);
        }

        User u = new User(
            Username = username,
            LastName = 'P0 Agent ' + key,
            Alias = key.left(8),
            Email = AGENT_EMAIL,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'GMT',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :AGENT_PROFILE LIMIT 1].Id,
            UserRoleId = [SELECT Id FROM UserRole WHERE DeveloperName = :agentRole LIMIT 1].Id
        );
        Database.DMLOptions options = new Database.DMLOptions();
        options.EmailHeader.triggerUserEmail = false;
        u.setOptions(options);
        insert u;
        return agentResult(u.Id, username, true, false);
    }

    // Finds the agent with this key, active or not.
    private static Map<String, Object> findAgent(String key) {
        String username = P0AgentSettings.agentUsername(key);
        if (username == null) throw fail(400, 'invalid_agent_key');
        String agentRole = P0AgentSettings.agentRole();
        List<User> users = [
            SELECT Id, IsActive FROM User
            WHERE Username = :username AND UserRole.DeveloperName = :agentRole AND Profile.Name = :AGENT_PROFILE
            LIMIT 1
        ];
        if (users.isEmpty()) throw fail(404, 'agent_not_found');
        return new Map<String, Object>{
            'userId' => users[0].Id, 'username' => username, 'active' => users[0].IsActive
        };
    }

    // Makes the agent hold exactly these grantable sets. An empty list removes all of them.
    private static Map<String, Object> setGrants(String userId, Map<String, Object> body) {
        User agent = loadAgent(userId);
        Set<String> names = requiredStrings(body, 'permissionSets');
        if (!names.isEmpty() && !agent.IsActive) throw fail(409, 'agent_inactive');
        Set<String> grantable = new Set<String>(P0AgentSettings.grantable());
        if (!grantable.containsAll(names)) throw fail(403, 'permission_set_not_grantable');
        Map<String, PermissionSet> sets = new Map<String, PermissionSet>();
        for (PermissionSet ps : [
            SELECT Id, Name, LicenseId, PermissionsModifyAllData, PermissionsViewAllData, PermissionsManageUsers,
                PermissionsAuthorApex, PermissionsCustomizeApplication, PermissionsManageProfilesPermissionsets
            FROM PermissionSet WHERE Name IN :names AND IsOwnedByProfile = false
        ]) {
            if (isTooBroad(ps)) throw fail(403, 'permission_set_too_broad');
            sets.put(ps.Name, ps);
        }
        if (sets.size() != names.size()) throw fail(404, 'permission_set_not_found');

        Set<String> remove = new Set<String>(grantable);
        remove.removeAll(names);
        if (names.isEmpty()) remove.add(APP_ACCESS_PERMISSION_SET);
        delete [
            SELECT Id FROM PermissionSetAssignment
            WHERE AssigneeId = :agent.Id AND PermissionSet.Name IN :remove
        ];
        if (!names.isEmpty()) ensureAssignment(agent.Id, appAccessId());
        for (PermissionSet ps : sets.values()) {
            ensurePermissionSetLicense(agent.Id, ps.LicenseId);
            ensureAssignment(agent.Id, ps.Id);
        }
        List<String> held = new List<String>(names);
        held.sort();
        return new Map<String, Object>{ 'permissionSets' => held };
    }

    // Sets that would let an agent read everything, change users or permissions, or change code.
    @TestVisible
    private static Boolean isTooBroad(PermissionSet ps) {
        return ps.PermissionsModifyAllData || ps.PermissionsViewAllData || ps.PermissionsManageUsers
            || ps.PermissionsAuthorApex || ps.PermissionsCustomizeApplication
            || ps.PermissionsManageProfilesPermissionsets;
    }

    private static Map<String, Object> listGrantable() {
        return new Map<String, Object>{ 'permissionSets' => P0AgentSettings.grantable() };
    }

    // Removes the assignments first: they survive deactivation and come back on reactivation.
    private static Map<String, Object> retire(String userId) {
        User agent = loadAgent(userId);
        List<PermissionSetAssignment> assignments = [
            SELECT Id FROM PermissionSetAssignment
            WHERE AssigneeId = :agent.Id AND PermissionSet.IsOwnedByProfile = false
        ];
        delete assignments;
        delete [SELECT Id FROM PermissionSetLicenseAssign WHERE AssigneeId = :agent.Id];
        if (agent.IsActive) update new User(Id = agent.Id, IsActive = false);
        return new Map<String, Object>{ 'removed' => assignments.size(), 'active' => false };
    }

    private static Id appAccessId() {
        return [SELECT Id FROM PermissionSet WHERE Name = :APP_ACCESS_PERMISSION_SET LIMIT 1].Id;
    }

    private static User loadAgent(String userId) {
        String agentRole = P0AgentSettings.agentRole();
        if (!USER_ID.matcher(userId).matches()) throw fail(400, 'invalid_user_id');
        List<User> users = [
            SELECT Id, IsActive FROM User
            WHERE Id = :userId AND UserRole.DeveloperName = :agentRole AND Profile.Name = :AGENT_PROFILE
            LIMIT 1
        ];
        if (users.isEmpty()) throw fail(404, 'agent_not_found');
        return users[0];
    }

    private static void ensurePermissionSetLicense(Id userId, Id licenseId) {
        if (licenseId == null || !String.valueOf(licenseId).startsWith(PERMISSION_SET_LICENSE_PREFIX)) return;
        if ([SELECT COUNT() FROM PermissionSetLicenseAssign
                WHERE AssigneeId = :userId AND PermissionSetLicenseId = :licenseId] == 0) {
            insert new PermissionSetLicenseAssign(AssigneeId = userId, PermissionSetLicenseId = licenseId);
        }
    }

    private static void ensureAssignment(Id userId, Id permissionSetId) {
        if ([SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId = :userId AND PermissionSetId = :permissionSetId] == 0) {
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId);
        }
    }

    private static Map<String, Object> agentResult(Id userId, String username, Boolean created, Boolean reactivated) {
        return new Map<String, Object>{
            'userId' => userId, 'username' => username, 'created' => created, 'reactivated' => reactivated
        };
    }

    private static List<String> pathSegments() {
        String uri = RestContext.request.requestURI;
        String rest = uri.substring(uri.indexOf(PATH_PREFIX) + PATH_PREFIX.length());
        List<String> segments = new List<String>();
        for (String segment : rest.split('/')) {
            if (String.isNotBlank(segment)) segments.add(EncodingUtil.urlDecode(segment, 'UTF-8'));
        }
        return segments;
    }

    private static Map<String, Object> requestBody() {
        Blob raw = RestContext.request.requestBody;
        if (raw == null || raw.size() == 0) throw fail(400, 'missing_body');
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(raw.toString());
        } catch (Exception e) {
            throw fail(400, 'invalid_json');
        }
    }

    private static String requiredString(Map<String, Object> body, String field) {
        Object value = body.get(field);
        if (!(value instanceof String) || String.isBlank((String) value)) throw fail(400, 'missing_' + field);
        return (String) value;
    }

    private static Set<String> requiredStrings(Map<String, Object> body, String field) {
        if (!(body.get(field) instanceof List<Object>)) throw fail(400, 'missing_' + field);
        Set<String> values = new Set<String>();
        for (Object value : (List<Object>) body.get(field)) {
            if (!(value instanceof String) || String.isBlank((String) value)) throw fail(400, 'invalid_' + field);
            values.add((String) value);
        }
        return values;
    }

    private static FacadeException fail(Integer status, String error) {
        FacadeException e = new FacadeException(error);
        e.status = status;
        return e;
    }

    public class FacadeException extends Exception {
        public Integer status;
    }
}
