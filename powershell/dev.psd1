# Replace the placeholder values below with your actual configuration data for the target environment. 
# This file is used by the PowerShell scripts to deploy and teardown the architecture in your Azure AD tenant.

@{
    APP_ID      = "00000000-0000-0000-0000-000000000000" # ID of the multi-tenant app provided by CDS
    TENANT_ID   = "00000000-0000-0000-0000-000000000000" # Target Azure AD Tenant ID
    ENV         = "Dev"                                  # Tier identifier (dev, test, prod)
    TEAMS       = @("Team1", "Team2", "Team3")           # Native array definition of groups
}
