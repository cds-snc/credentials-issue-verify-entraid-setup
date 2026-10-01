# Entra ID Management Guide: GCIV Affiniti Quest Teams
This automation package streamlines the deployment, continuous tracking, and decommissioning of corporate teams onto the GCIV Affiniti Quest service by managing:

* **Local Instantiation:** Deploys or validates the multi-tenant GCIV App Registration (Service Principal) within your targeted tenant.
* **Group Topologies:** Creates, links, or completely purges multi-layered Microsoft Entra ID security groups natively.
* **Role Entitlements:** Maps functional security groups to custom App Roles during setup, and cleanly strips them out during cleanup.

## 📋 Prerequisites
Before executing the scripts, ensure your local environment and deployment identity meet the following requirements:
* **PowerShell:** Version 7.0 or higher is required for modern Microsoft Graph compatibility.
* **Entra ID Permissions:** Your account requires the following privileged administrative directory roles:
    * *Group Administrator* (to create, delete, nest, and audit security groups).
    * *Application Administrator* or *Cloud Application Administrator* (to read application manifests and manage app role entitlements).

---

## 🛠️ What the Automation Does

### Provisioning (`deploy_setup.ps1`)
1. Imports execution parameters securely from an immutable PowerShell Data File (`.psd1`) to completely bypass messy command-line string inputs.
2. Maps out the architecture matrix and scans the live directory for naming collisions. If any targeted group exists and contains pre-existing members, it blocks execution to protect production states.
3. Creates a global environment root group if it does not already exist: `GCIV-AffinitiQuest-[ENV]-Users`.
4. Provisions team parent structural groups for every team specified, then nests them cleanly inside the root environment group.
5. Instantiates a Service Principal for your custom Application ID locally if one does not yet exist.
6. Generates and links precise Role Groups (`Marketer`, `Manager`, `Admin`) for each team, mapping the matching Entra App Roles to those groups.

### Teardown (`teardown_architecture.ps1`)
1. Unpacks the same targeted configuration file to pinpoint the exact environment scoping to tear down.
2. Triggers a mandatory interactive guard gate, forcing the operator to manually type the exact name of the file to verify intent before executing any directory changes.
3. Interrogates the local Service Principal and caches all app role assignments to reduce overhead.
4. Traverses the environment matrix in exact reverse chronological order, dropping app role assignments first before permanently deleting the child role groups.
5. Collapses parent team groups and the environment's global root users group, leaving the tenant entirely clean.

---

## 🛑 Automated Error Rollback
The provisioning script features an intelligent fail-safe routine. If any command fails, or if execution is manually interrupted mid-flight:
* A script-level trap intercepts the failure.
* The script reads a live runtime history stack tracking created resources.
* It deletes all newly created groups in reverse chronological order.
* Your tenant state is immediately reset to original conditions, preventing partial configurations.

---

## 🚀 Execution Instructions

### 1. Configure Your Environment Data File
Create a PowerShell Data File named **`dev.psd1`** in your working script directory. Ensure all entries use valid structural configurations:

```powershell
# dev.psd1
@{
    APP_ID      = "00000000-0000-0000-0000-000000000000" # ID of the multi-tenant app provided by CDS
    TENANT_ID   = "00000000-0000-0000-0000-000000000000" # Target Azure AD Tenant ID
    ENV         = "Dev"                                  # Environment identifier (e.g., Dev, Test, Prod)
    TEAMS       = @("Team1", "Team2", "Team3")           # Array of internal team names to create security groups for. 
}
```

### 2. Configure System Execution Policy
Run your PowerShell console as an **Administrator** and adjust your execution policy to allow locally written scripts to run safely in your active process:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
```

### 3. Run the Provisioning Script
To deploy the entire nested security matrix, execute the deployment script. You can pass a specific config path as an argument, or omit it to default to `dev.psd1`:

```powershell
# Executes using the default dev.psd1 profile
.\deploy_setup.ps1

# Executes targeting an alternative environment profile
.\deploy_setup.ps1 configs\prod.psd1
```
*Note: If prompted during module loading, authenticate your Azure session securely via your web browser when the console redirects.*

---

## 🗂️ Architecture Lifecycle Visual
The automation scripts act upon a multi-layered nested hierarchy. Given an environment profile of 'Dev' and a team named 'Sales', the provisioning script constructs this layout, and the teardown engine safely erases it from the bottom up:

```text
GCIV-AffinitiQuest-Dev-Users                      <- (Global Environment Root Group)
  └── GCIV-AffinitiQuest-Dev-Sales                <- (Team Parent Group)
        ├── GCIV-AffinitiQuest-Dev-Sales-Marketer <- (Assigned App Role: "Marketer")
        ├── GCIV-AffinitiQuest-Dev-Sales-Manager  <- (Assigned App Role: "Manager")
        └── GCIV-AffinitiQuest-Dev-Sales-Admin    <- (Assigned App Role: "Admin")
```

## 🗑️  Environment Teardown and Resource Purge

> ⚠️ **Critical: Target Decommissioning Risk**  
> Running the teardown script permanently deletes all scoped Entra ID security groups and app entitlements for the targeted environment. When executed, you must type the **exact filename of your configuration file** (e.g., `dev.psd1` or `prod.psd1`) at the interactive prompt to authorize the teardown.

To permanently delete all deployed security groups and strip away all application role mappings for a given environment, execute the teardown script:
```powershell
# Executes teardown using the default dev.psd1 profile
.\teardown_architecture.ps1

# Executes teardown targeting an alternative environment profile
.\teardown_architecture.ps1 configs\prod.psd1
```