# ==========================================
# DATA FILE LOADER
# ==========================================


$TargetFile = if ($args) { $args } else { "dev.psd1" } #fallback to default dev.psd1 if no argument is provided

if (-not (Test-Path -Path $TargetFile -PathType Leaf)) {
    Write-Error "❌ Error: Configuration Data file '${TargetFile}' not found."
    Write-Host "Usage: .\teardown_architecture.ps1 [path/to/environment.psd1]"
    exit 1
}

# Native parsing engine: completely data-safe and unlocks top-level object properties
$Config = Import-PowerShellDataFile -Path $TargetFile
$ActiveFileName = Split-Path $TargetFile -Leaf

# Architecture System Constants
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

# --- PRE-FLIGHT VALIDATION OF UNPACKED OBJECT ---
if ([string]::IsNullOrWhiteSpace($Config.APP_ID) -or $Config.APP_ID -eq "00000000-0000-0000-0000-000000000000") {
    Write-Error "❌ Error: APP_ID value inside the data file must be a valid application UUID."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($Config.TENANT_ID) -or $Config.TENANT_ID -eq "00000000-0000-0000-0000-000000000000") {
    Write-Error "❌ Error: TENANT_ID value inside the data file must be a valid tenant UUID."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($Config.ENV)) {
    Write-Error "❌ Error: ENV property inside configuration file cannot be empty."
    exit 1
}
if ($null -eq $Config.TEAMS -or $Config.TEAMS.Count -eq 0) {
    Write-Error "❌ Error: TEAMS array inside configuration data file cannot be empty."
    exit 1
}

# Unify items natively into a unique HashSet
$TEAMS_SET = [System.Collections.Generic.HashSet[string]]::new()
foreach ($team in $Config.TEAMS) {
    if (-not [string]::IsNullOrWhiteSpace($team)) {
        [void]$TEAMS_SET.Add($team.Trim())
    }
}

Write-Host "Configurations validated. Context established successfully."
Write-Host "Tenant ID:      $($Config.TENANT_ID)"
Write-Host "Application ID: $($Config.APP_ID)"
Write-Host "Environment:    $($Config.ENV)"
Write-Host "Teams targeted: $($TEAMS_SET -join ', ')"

# --- MANDATORY INTERACTIVE DATA FILE NAME CONFIRMATION GATE ---
Write-Host "`n🚨 WARNING: PERMANENT DATA DESTRUCTION RISK 🚨" -ForegroundColor Red
Write-Host "You are executing a script that will permanently delete all '(Config.ENV)' security groups and App Role mappings!" -ForegroundColor Yellow
\$UserInput = Read-Host "To confirm this action, please type the exact configuration filename (Expected: '\${ActiveFileName}')"

if (UserInput -ne ActiveFileName) {
    Write-Error "❌ Destruction aborted. Input mismatch (Expected: 'ActiveFileName', Received: '{UserInput}')."
    Write-Host "No directory changes were executed."
    exit 1
}
Write-Host "✅ Confirmation verified. Proceeding..." -ForegroundColor Green

# Connect to Azure account and required MSGraph scopes
try {
    Write-Host "`nConnecting to Azure Account..."
    Connect-AzAccount -TenantId $Config.TENANT_ID -ErrorAction Stop
    Write-Host "Done."

    Write-Host "Connecting to required MS Graph scopes..."
    $RequiredScopes = @(
        "GroupMember.ReadWrite.All",
        "Group.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All"
    )
    Connect-MgGraph -TenantId $Config.TENANT_ID -Scopes $RequiredScopes -ErrorAction Stop
    Write-Host "Done."
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

# === PHASE 1: TARGET RESOLUTION & PERFORMANCE CACHING ===
Write-Host "`n📥 Resolving Service Principal and loading entitlements cache..." -ForegroundColor Cyan
\$SP = Get-MgServicePrincipal -Filter "appId eq '(Config.APP_ID)'" -ErrorAction SilentlyContinue

if (null -eq SP) {
    Write-Warning "⚠️ Service Principal with App ID (Config.APP_ID) not found. App role assignments cannot be audited natively."
    \$AssignmentsCache = @()
} else {
    Write-Host "Service Principal located (Object ID: (SP.Id)). Fetching role assignment table..."
    AssignmentsCache = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId SP.Id -All -ErrorAction SilentlyContinue
}

# === PHASE 2: DESTRUCTION ENGINE (REVERSE CHRONOLOGICAL ORDER) ===

# 1. Clean up Leaf-Level Functional Role Groups and Entitlements
Write-Host "`n🧹 Deleting nested functional Role groups and App Role assignments..." -ForegroundColor Yellow
foreach ($TEAM in $TEAMS_SET) {
    foreach ($ROLE in $AQ_ROLES) {
        $RoleGroupName = "${SECURITY_GROUP_PREFIX}-$($Config.ENV)-${TEAM}-${ROLE}"
        Write-Host "Processing role group: ${RoleGroupName}..."
        
        $RoleGroup = Get-MgGroup -Filter "displayName eq '${RoleGroupName}'" -ErrorAction SilentlyContinue
        if ($RoleGroup) {
            # Strip App Role entitlements using local in-memory processing
            if ($null -ne $SP -and $null -ne $AssignmentsCache) {
                $TargetAssignments = $AssignmentsCache | Where-Object { $_.PrincipalId -eq $RoleGroup.Id }
                foreach ($Assignment in $TargetAssignments) {
                    Write-Host "   Removing App Role assignment: $($Assignment.Id)..."
                    Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SP.Id -AppRoleAssignmentId $Assignment.Id -ErrorAction SilentlyContinue
                }
            }
            
            # Wipe the role group from the tenant directory
            Write-Host "🗑️ Deleting group..." -ForegroundColor Red
            Remove-MgGroup -GroupId $RoleGroup.Id -ErrorAction SilentlyContinue
            Write-Host "✅ Successfully removed." -ForegroundColor Green
        } else {
            Write-Host "ℹ️ Group does not exist. Skipping."
        }
    }
}

# 2. Clean up Parent Structural Team Groups
Write-Host "`n🧹 Deleting parent Team structural groups..." -ForegroundColor Yellow
foreach ($TEAM in $TEAMS_SET) {
    $TeamGroupName = "${SECURITY_GROUP_PREFIX}-$($Config.ENV)-${TEAM}"
    Write-Host "Processing team group: ${TeamGroupName}..."
    
    $TeamGroup = Get-MgGroup -Filter "displayName eq '${TeamGroupName}'" -ErrorAction SilentlyContinue
    if ($TeamGroup) {
        Write-Host "🗑️ Deleting group..." -ForegroundColor Red
        Remove-MgGroup -GroupId $TeamGroup.Id -ErrorAction SilentlyContinue
        Write-Host "✅ Successfully removed." -ForegroundColor Green
    } else {
        Write-Host "ℹ️ Group does not exist. Skipping."
    }
}

# 3. Clean up Global Environment Root Users Group
Write-Host "`n🧹 Deleting global Environment Root Users security group..." -ForegroundColor Yellow
$RootGroupName = "${SECURITY_GROUP_PREFIX}-$($Config.ENV)-Users"
Write-Host "Processing root group: ${RootGroupName}..."

$RootGroup = Get-MgGroup -Filter "displayName eq '${RootGroupName}'" -ErrorAction SilentlyContinue
if ($RootGroup) {
    Write-Host "🗑️ Deleting root group..." -ForegroundColor Red
    Remove-MgGroup -GroupId $RootGroup.Id -ErrorAction SilentlyContinue
    Write-Host "✅ Successfully removed." -ForegroundColor Green
} else {
    Write-Host "ℹ️ Root group does not exist. Skipping."
}

Write-Host "`n🎉 Teardown process completed successfully. Tenant state pristine." -ForegroundColor Cyan
