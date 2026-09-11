# Initialize values for required inputs
$ENV = ""
$APP_ID = ""
$TENANT_ID = ""

# Track dynamically created assets for precise pinpoint rollback if execution fails
$CreatedGroups = [System.Collections.Generic.List[string]]::new()
$ServicePrincipalCreated = $false

# Wrap prompts for inputs in while loops that will persist until required input is received
while ([string]::IsNullOrWhiteSpace($ENV)) {
    $ENV = Read-Host -Prompt "Enter Environment Name (e.g., dev, test, prod)"
}
while ([string]::IsNullOrWhiteSpace($APP_ID)) {
    $APP_ID = Read-Host -Prompt "Enter Application ID (Provided by CDS)"
}
while ([string]::IsNullOrWhiteSpace($TENANT_ID)) {
    $TENANT_ID = Read-Host -Prompt "Enter Tenant ID"
}

Write-Host "Inputs received. Proceeding..."

# Set PSGallery as a trusted repository to avoid prompts during module installation
Write-Host "Adding PowerShell Gallery as trusted repository"
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
Write-Host "Done."

# Install required modules
Write-Host "Installing required modules..."
Install-Module -Name Az.Resources -Scope CurrentUser -Force
Install-Module Microsoft.Graph -Scope CurrentUser -Force
Write-Host "Done."

# Define the central emergency rollback function
function Invoke-EmergencyRollback {
    Write-Host "`n⚠️ ERROR ENCOUNTERED, COMMENCING AUTOMATIC ROLLBACK UNINSTALL..." -ForegroundColor Yellow
    
    # 1. Purge created groups in reverse order to cleanly un-nest memberships first
    if ($CreatedGroups.Count -gt 0) {
        for ($i = $CreatedGroups.Count - 1; $i -ge 0; $i--) {
            $GroupId = $CreatedGroups[$i]
            try {
                Write-Host "Rolling back group deletion (ID: $GroupId)..."
                Remove-MgGroup -GroupId $GroupId -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Failed to cleanly remove group $GroupId during rollback: $_"
            }
        }
    }

    # 2. Purge local service principal if it was instantiated during this run
    if ($ServicePrincipalCreated) {
        try {
            $SP = Get-MgServicePrincipal -Filter "appId eq '$APP_ID'" -ErrorAction SilentlyContinue
            if ($SP) {
                Write-Host "Rolling back Service Principal creation..."
                Remove-MgServicePrincipal -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Failed to remove service principal during rollback: $_"
        }
    }

    Write-Host "⛔ Tenant state successfully reset to original conditions. Exiting script safely." -ForegroundColor Green
}

# Connect to Azure account and required MSGraph scopes
try {
    Write-Host "Connecting to Azure Account..."
    Connect-AzAccount -ErrorAction Stop
    Write-Host "Done."

    Write-Host "Connecting to required MS Graph scopes (Groups Administrator)..."
    Connect-MgGraph -TenantId $TENANT_ID -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "DelegatedPermissionGrant.ReadWrite.All" -ErrorAction Stop
    Write-Host "Done."
} catch {
    Write-Error "Authentication failed: $_"
    exit
}

# Create service principal using $APP_ID
try {
    Write-Host "Creating service principal..."
    New-AzADServicePrincipal -ApplicationId $APP_ID -ErrorAction Stop
    $ServicePrincipalCreated = $true # Tag state for rollback tracking
    
    # Re-fetch new service principal via Graph to guarantee all AppRoles properties are fully loaded
    $SP_LIST = Get-MgServicePrincipal -Filter "appId eq '$APP_ID'" -ErrorAction Stop
    $SP = $SP_LIST[0]
    $SP_ID = $SP.Id
    Write-Host "Done."
} catch {
    Write-Error "Failed to create or fetch Service Principal: $_"
    Invoke-EmergencyRollback
    exit
}

# Get MSGraph service principal Object ID and store in $GRAPH_SP_ID
try {
    $GRAPH_SP_ID = (Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'" -ErrorAction Stop).Id
} catch {
    Write-Error "Failed to fetch Microsoft Graph Service Principal: $_"
    Invoke-EmergencyRollback
    exit
}

# Store required MSGraph permissions in $SCOPE
$SCOPE = "User.Read openid profile"

# Delegate MSGraph permissions to service principal
try {
    Write-Host "Delegating required MSGraph permissions to service principal..."
    $OAuthParams = @{
        ClientId    = $SP_ID
        ConsentType = "Principal"
        PrincipalId = $SP_ID
        ResourceId  = $GRAPH_SP_ID
        Scope       = $SCOPE
    }
    New-MgOauth2PermissionGrant @OAuthParams -ErrorAction Stop
    Write-Host "Done."
} catch {
    Write-Warning "Failed to delegate standard OAuth permissions (may already exist): $_"
}

# Prefix to add to the beginning of each security group
$SECURITY_GROUP_PREFIX = "GCIV-AffinitiQuest"

# Define parameters for $AQ_USERS_GROUP security group to be created
$GROUP_PARAMS = @{
    DisplayName     = "$SECURITY_GROUP_PREFIX-$ENV-Users"
    MailEnabled     = $false
    SecurityEnabled = $true
}

# Create $AQ_USERS_GROUP and capture its Display Name and ID
try {
    Write-Host "Creating '$SECURITY_GROUP_PREFIX-$ENV-Users' group..."
    $AQ_USERS_GROUP_OBJ = New-MgGroup @GROUP_PARAMS -ErrorAction Stop
    $AQ_USERS_GROUP_NAME = $AQ_USERS_GROUP_OBJ.DisplayName
    $AQ_USERS_GROUP_ID = $AQ_USERS_GROUP_OBJ.Id
    $CreatedGroups.Add($AQ_USERS_GROUP_ID) # Log creation tracking
    Write-Host "Done."
} catch {
    Write-Error "Error: Failed to create '$SECURITY_GROUP_PREFIX-$ENV-Users' group. Ensure your account has Group Administrator rights. Error: $_"
    Invoke-EmergencyRollback
    exit
}

# Wrap prompt for $teamsInput in a while loop that will persist until at least one team name is entered
$teamsInput = ""
while ([string]::IsNullOrWhiteSpace($teamsInput)) {
    $teamsInput = Read-Host -Prompt "Enter at least one team name, or more separated by commas (e.g., team1, team2)"
}

# Split teams by the comma and automatically trim any accidental whitespace
$TEAMS_ARRAY = $teamsInput -split ',' | ForEach-Object { $_.Trim() }

# Create $TEAMS HashSet from the $TEAMS_ARRAY to ensure that there are no duplicate team names
$TEAMS = [System.Collections.Generic.HashSet[string]]@($TEAMS_ARRAY)

# Output the result to verify it's an array
Write-Host "The following team(s) have been captured:"
$TEAMS | ForEach-Object { "$_" }

Write-Host "Commencing the creation of required AQ Role groups for each team..."

# Store each AQ Role in $AQ_ROLES array
$AQ_ROLES = 'Marketer', 'Manager', 'Admin'

# Iterate through $TEAMS and create security group for each $TEAM
foreach ($TEAM in $TEAMS) {

    $ENTRA_TEAM_GROUP = "$SECURITY_GROUP_PREFIX-$ENV-$TEAM"

    try {
        # Define parameters for $ENTRA_TEAM_GROUP security group
        $GROUP_PARAMS = @{
            DisplayName     = "$ENTRA_TEAM_GROUP"
            MailEnabled     = $false
            SecurityEnabled = $true
        }

        # Create $ENTRA_TEAM_GROUP and capture its Object ID
        Write-Host "Creating '$ENTRA_TEAM_GROUP' group..."
        $ENTRA_TEAM_GROUP_ID = (New-MgGroup @GROUP_PARAMS -ErrorAction Stop).Id
        $CreatedGroups.Add($ENTRA_TEAM_GROUP_ID) # Log creation tracking
        Write-Host "Done."

        # Add $ENTRA_TEAM_GROUP to $AQ_USERS_GROUP
        Write-Host "Adding '$ENTRA_TEAM_GROUP' group to '$AQ_USERS_GROUP_NAME' group..."
        New-MgGroupMember -GroupId $AQ_USERS_GROUP_ID -DirectoryObjectId $ENTRA_TEAM_GROUP_ID -ErrorAction Stop
        Write-Host "Done."
    } catch {
        Write-Error "Failed to set up Team Group '$ENTRA_TEAM_GROUP': $_"
        Invoke-EmergencyRollback
        exit
    }

    # Iterate through $AQ_ROLES and create required security groups
    foreach ($ROLE in $AQ_ROLES) {

        $GROUP = "$TEAM-$ROLE"
        $AQ_ROLE_GROUP = "$SECURITY_GROUP_PREFIX-$ENV-$GROUP"
         
        try {
            # Define parameters for $AQ_ROLE_GROUP security group
            $GROUP_PARAMS = @{
                DisplayName     = "$AQ_ROLE_GROUP"
                MailEnabled     = $false
                SecurityEnabled = $true
            }
            
            # Create $AQ_ROLE_GROUP and capture its Object ID
            Write-Host "Creating '$AQ_ROLE_GROUP'..."
            $AQ_ROLE_GROUP_ID = (New-MgGroup @GROUP_PARAMS -ErrorAction Stop).Id
            $CreatedGroups.Add($AQ_ROLE_GROUP_ID) # Log creation tracking
            Write-Host "Done."

            # Get corresponding App Role ID for current $ROLE from the loaded service principal.
            $APP_ROLE_ID = ($SP.AppRoles | Where-Object { $_.DisplayName -eq $ROLE }).Id

            if ($null -eq $APP_ROLE_ID) {
                Write-Warning "Could not find an App Role named '$ROLE' on the Service Principal. Skipping assignment."
                continue
            }

            # Assign corresponding app role to the group that was just created
            Write-Host "Assigning $ROLE role to '$AQ_ROLE_GROUP' group..."
            New-MgGroupAppRoleAssignment -GroupId $AQ_ROLE_GROUP_ID -PrincipalId $AQ_ROLE_GROUP_ID -ResourceId $SP_ID -AppRoleId $APP_ROLE_ID -ErrorAction Stop
            Write-Host "Done."

            # Add $AQ_ROLE_GROUP to $ENTRA_TEAM_GROUP
            Write-Host "Adding '$AQ_ROLE_GROUP' group to '$ENTRA_TEAM_GROUP' group..."
            New-MgGroupMember -GroupId $ENTRA_TEAM_GROUP_ID -DirectoryObjectId $AQ_ROLE_GROUP_ID -ErrorAction Stop
            Write-Host "Done."
        } catch {
            Write-Error "Failed to set up Role Group '$AQ_ROLE_GROUP': $_"
            Invoke-EmergencyRollback
            exit
        }
    }
    Write-Host "Creation of AQ Role groups for '$TEAM' team have completed successfully." -ForegroundColor Green
}

Write-Host "Setup script has completed successfully!" -ForegroundColor Green