// The org's P0 agent settings: the `Default` record of P0_Agent_Setting__mdt,
// and the grantable list in P0_Grantable_Permission_Set__mdt.
public without sharing class P0AgentSettings {

    public static final String AGENT_PROFILE = 'Salesforce API Only System Integrations';
    public static final String APP_ACCESS_PERMISSION_SET = 'P0_Agent_App_Access';
    private static final Pattern AGENT_KEY = Pattern.compile('[a-z0-9][a-z0-9-]{0,39}');

    @TestVisible private static P0_Agent_Setting__mdt settingOverride;
    @TestVisible private static List<String> grantableOverride;

    public class MissingSettingException extends Exception {}

    public static P0_Agent_Setting__mdt current() {
        if (settingOverride != null) return settingOverride;
        P0_Agent_Setting__mdt setting = P0_Agent_Setting__mdt.getInstance('Default');
        if (setting == null) throw new MissingSettingException('P0_Agent_Setting__mdt.Default is missing');
        return setting;
    }

    public static String agentRole() {
        return current().Agent_Role__c;
    }

    /** The gateway's issuer URL, without a trailing slash. */
    public static String gatewayIssuer() {
        return current().Gateway_Issuer__c.removeEnd('/');
    }

    public static List<String> grantable() {
        if (grantableOverride != null) return grantableOverride;
        List<String> names = new List<String>();
        for (P0_Grantable_Permission_Set__mdt row : P0_Grantable_Permission_Set__mdt.getAll().values()) {
            names.add(row.Permission_Set_Name__c);
        }
        return names;
    }

    /** @return the agent's username, or null when the key is not valid */
    public static String agentUsername(String agentKey) {
        if (agentKey == null || !AGENT_KEY.matcher(agentKey).matches()) return null;
        // Usernames are unique across all Salesforce orgs, so the org id is part of it.
        return 'p0-agent-' + agentKey + '@' + UserInfo.getOrganizationId().toLowerCase() + '.agents.p0.dev';
    }
}
