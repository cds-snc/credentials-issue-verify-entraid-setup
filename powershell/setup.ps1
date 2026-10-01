# ==========================================
#         STATIC CONFIGURATION VARIABLES
# ==========================================
$APP_ID      = "00000000-0000-0000-0000-000000000000" # ID of the multi-tenant application provided by CDS
$TENANT_ID   = "00000000-0000-0000-0000-000000000000" # ID of the target Azure AD tenant where the service principal and groups will be created
$ENV         = "dev" # Environment name (e.g., dev, test, prod)
$TEAMS_ARRAY = @("team1", "team2", "team3") # Array of internal teams to create security groups for. Add as many as needed.

# ==========================================
#         INITIALIZE SYSTEM STATE
# ==========================================
$CreatedGroups = [System.Collections.Generic.List[string]]::new()
$ServicePrincipalCreated = $false

$SECURITY_GROUP_PREFIX = "GCIV-AffinitiQuest"
$AQ_ROLES = @('Marketer', 'Manager', 'Admin')

# Set PSGallery as a trusted repository to avoid prompts during module installation
Write-Host "Adding PowerShell Gallery as trusted repository..."
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
Write-Host "Done."

# Install required modules
Write-Host "Installing required modules..."
Install-Module -Name Az.Resources -Scope CurrentUser -Force -ErrorAction SilentlyContinue
Install-Module Microsoft.Graph -Scope CurrentUser -Force -ErrorAction SilentlyContinue
Write-Host "Done."

# Define the central emergency rollback function
function Invoke-EmergencyRollback {
    Write-Host "`n⚠️ ERROR ENCOUNTERED, COMMENCING AUTOMATIC ROLLBACK UNINSTALL..." -ForegroundColor Yellow
    
    # 1. Purge created groups in reverse order to cleanly un-nest memberships first
    $count = $CreatedGroups.Count
    if ($count -gt 0) {
        for ($i = ($count - 1); $i -ge 0; $i--) {
            $GroupId = $CreatedGroups[$i]
            try {
                Write-Host "Rolling back group deletion (ID: ${GroupId})..."
                Remove-MgGroup -GroupId $GroupId -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Failed to cleanly remove group ${GroupId} during rollback: $_"
            }
        }
    }

    # 2. Purge local service principal if it was instantiated during this run
    if ($ServicePrincipalCreated) {
        try {
            $SP = Get-MgServicePrincipal -Filter "appId eq '${APP_ID}'" -ErrorAction SilentlyContinue
            if ($SP) {
                Write-Host "Rolling back Service Principal creation..."
                Remove-MgServicePrincipal -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Failed to remove service principal during rollback: $_"
        }
    }

    Write-Host "⛔ Tenant state successfully reset to original conditions. Exiting script safely." -ForegroundColor Red
}

# --- PRE-FLIGHT VALIDATION OF VARIABLES ---
if ([string]::IsNullOrWhiteSpace($APP_ID) -or $APP_ID -eq "00000000-0000-0000-0000-000000000000") {
    Write-Error "❌ Error: APP_ID variable must be set to a valid application UUID."
    exit
}
if ([string]::IsNullOrWhiteSpace($TENANT_ID) -or $TENANT_ID -eq "00000000-0000-0000-0000-000000000000") {
    Write-Error "❌ Error: TENANT_ID variable must be set to a valid tenant UUID."
    exit
}
if ([string]::IsNullOrWhiteSpace($ENV)) {
    Write-Error "❌ Error: ENV variable cannot be empty."
    exit
}
if ($TEAMS_ARRAY.Count -eq 0) {
    Write-Error "❌ Error: TEAMS_ARRAY variable cannot be empty. Add at least one team."
    exit
}

# Process the array into a unique HashSet
$TEAMS = [System.Collections.Generic.HashSet[string]]::new()
foreach ($team in $TEAMS_ARRAY) {
    if (-not [string]::IsNullOrWhiteSpace($team)) {
        [void]$TEAMS.Add($team.Trim())
    }
}

Write-Host "Configurations validated. Proceeding..."
Write-Host "Tenant ID:      ${TENANT_ID}"
Write-Host "Application ID: ${APP_ID}"
Write-Host "Environment:    ${ENV}"
Write-Host "Teams targeted: $($TEAMS -join ', ')"

# Connect to Azure account and required MSGraph scopes
try {
    Write-Host "Connecting to Azure Account..."
    Connect-AzAccount -TenantId $TENANT_ID -ErrorAction Stop
    Write-Host "Done."

    Write-Host "Connecting to required MS Graph scopes..."
    # Optimized footprint: GroupMember handles lifecycle/nesting; AppRoleAssignment handles permission mapping
    $RequiredScopes = @(
        "GroupMember.ReadWrite.All",
        "Group.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All"
    )
    Connect-MgGraph -TenantId $TENANT_ID -Scopes $RequiredScopes -ErrorAction Stop
    Write-Host "Done."
} catch {
    Write-Error "Authentication failed: $_"
    exit
}


# === PHASE 1: PRE-FLIGHT DUPLICATE GROUP VERIFICATION ===

Write-Host "Running pre-flight checks for group naming collisions..." -ForegroundColor Cyan
$GroupsToValidate = [System.Collections.Generic.List[string]]::new()
$GroupsToValidate.Add("${SECURITY_GROUP_PREFIX}-${ENV}-Users")

foreach ($TEAM in $TEAMS) {
    $GroupsToValidate.Add("${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}")
    foreach ($ROLE in $AQ_ROLES) {
        $GroupsToValidate.Add("${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}-${ROLE}")
    }
}

$CollisionsFound = $false
foreach ($GroupName in $GroupsToValidate) {
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '${GroupName}'" -ErrorAction SilentlyContinue
    if ($ExistingGroup) {
        Write-Error "Naming Collision Detected: A group named '${GroupName}' already exists in this tenant (ID: $($ExistingGroup.Id))."
        $CollisionsFound = $true
    }
}

if ($CollisionsFound) {
    Write-Error "Pre-flight checks failed. Halting setup to prevent overwriting existing structures."
    exit
}
Write-Host "Pre-flight checks passed! No naming collisions found. Proceeding..." -ForegroundColor Green


# === PHASE 2: INFRASTRUCTURE DEPLOYMENT ===

# Verify if Service Principal already exists, if not, create it
try {
    $ExistingSP = Get-MgServicePrincipal -Filter "appId eq '${APP_ID}'" -ErrorAction SilentlyContinue
    if ($ExistingSP) {
        Write-Host "Service Principal already exists in this tenant."
        $SP = $ExistingSP
        $SP_ID = $SP.Id
    } else {
        Write-Host "Instantiating multi-tenant service principal..."
        New-AzADServicePrincipal -ApplicationId $APP_ID -ErrorAction Stop
        $ServicePrincipalCreated = $true 
       
        # Re-fetch new service principal via Graph to guarantee all AppRoles properties are fully loaded
        $SP_LIST = Get-MgServicePrincipal -Filter "appId eq '${APP_ID}'" -ErrorAction Stop
        $SP = $SP_LIST[0]
        $SP_ID = $SP.Id
        Write-Host "Done."
    }
} catch {
    Write-Error "Failed to create or fetch Service Principal: $_"
    Invoke-EmergencyRollback
    exit
}

# Create Parent Users Security Group
$AQ_USERS_GROUP_PARAMS = @{
    DisplayName     = "${SECURITY_GROUP_PREFIX}-${ENV}-Users"
    MailEnabled     = $false
    SecurityEnabled = $true
    MailNickname    = "${SECURITY_GROUP_PREFIX}-${ENV}-Users"
}

try {
    Write-Host "Creating '${SECURITY_GROUP_PREFIX}-${ENV}-Users' group..."
    $AQ_USERS_GROUP_OBJ = New-MgGroup @AQ_USERS_GROUP_PARAMS -ErrorAction Stop
    $AQ_USERS_GROUP_ID = $AQ_USERS_GROUP_OBJ.Id
    $CreatedGroups.Add($AQ_USERS_GROUP_ID)
    Write-Host "Done."
} catch {
    Write-Error "Error: Failed to create users group: $_"
    Invoke-EmergencyRollback
    exit
}


# === PHASE 3: TEAM & ROLE ARCHITECTURE NESTING ===
Write-Host "Commencing the creation of required AQ Role groups for each team..."

foreach ($TEAM in $TEAMS) {
    # 1. Create Parent Team Group
    $TeamGroupName = "${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}"
    $TeamGroupParams = @{
        DisplayName     = $TeamGroupName
        MailEnabled     = $false
        SecurityEnabled = $true
        MailNickname    = $TEAM
    }
    
    try {
        Write-Host "Creating parent group for team: ${TeamGroupName}..."
        $TeamGroupObj = New-MgGroup @TeamGroupParams -ErrorAction Stop
        $TeamGroupId = $TeamGroupObj.Id
        $CreatedGroups.Add($TeamGroupId)
        
        # Nest Team Group inside global Users Group
        New-MgGroupMember -GroupId $AQ_USERS_GROUP_ID -DirectoryObjectId $TeamGroupId -ErrorAction Stop
    } catch {
        Write-Error "Failed during architecture creation for team ${TEAM}: $_"
        Invoke-EmergencyRollback
        exit
    }

    # 2. Create and Assign Role Functional Groups
    foreach ($ROLE in $AQ_ROLES) {
        $RoleGroupName = "${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}-${ROLE}"
        $RoleGroupParams = @{
            DisplayName     = $RoleGroupName
            MailEnabled     = $false
            SecurityEnabled = $true
            MailNickname    = "${TEAM}-${ROLE}"
        }

        try {
            Write-Host "Creating role functional group: ${RoleGroupName}..."
            $RoleGroupObj = New-MgGroup @RoleGroupParams -ErrorAction Stop
            $RoleGroupId = $RoleGroupObj.Id
            $CreatedGroups.Add($RoleGroupId)

            # Nest Role Group inside Parent Team Group
            New-MgGroupMember -GroupId $TeamGroupId -DirectoryObjectId $RoleGroupId -ErrorAction Stop

            # Look up matching App Role definition on the multi-tenant service principal
            $TargetAppRole = $SP.AppRoles | Where-Object { $_.DisplayName -eq $ROLE }

            if ($TargetAppRole) {
                Write-Host "Assigning app role '${ROLE}' to group..."
                $AssignmentParams = @{
                    PrincipalId = $RoleGroupId
                    ResourceId  = $SP_ID
                    AppRoleId   = $TargetAppRole.Id
                }
                New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $SP_ID @AssignmentParams -ErrorAction Stop
            } else {
                Write-Warning "Application Role '${ROLE}' not found in manifest definition for App ID ${APP_ID}."
            }
        } catch {
            Write-Error "Failed to fully map role ${ROLE} for team ${TEAM}: $_"
            Invoke-EmergencyRollback
            exit
        }
    }
}

Write-Host "✅ Setup completed successfully. All components configured." -ForegroundColor Green
