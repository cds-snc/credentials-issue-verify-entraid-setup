## Entra ID Provisioning Guide: GCIV Affiniti Quest Teams
This automation package streamlines the onboarding of corporate teams onto the GCIV Affiniti Quest service by managing:

* Local Instantiation: Deploys the multi-tenant GCIV App Registration (Service Principal) to the local tenant.
* Group Topologies: Creates and configures the required Microsoft Entra ID security groups.
* Role Assignments: Links these security groups to their corresponding custom App Roles.

## 📋 Prerequisites
Before executing the pipeline, ensure your local environment and deployment identity meet the following requirements:

* Azure CLI: Must be installed and updated (az --version).
* jq: Must be installed and updated for validation and teardown scripts (jq --version)
* Active Session: You must be actively logged into the correct tenant using az login.
* Entra ID Privileges: Your deployment account requires the following administrative directory roles:
    * Group Administrator (to create, delete, and nest security groups).
    * Application Administrator or Cloud Application Administrator (to grant API permissions and assign app roles).

------------------------------
## 🛠️ What the Automation Does
### 1. Provisioning (deploy_setup.sh)
  1. Maps out the intended architecture matrix and checks the live directory for naming collisions. If any group exists, it blocks execution to protect production states.
  2. Creates a global root group for the target environment if it does not already exist: GCIV-AffinitiQuest-$ENV-Users.
  3. Creates distinct parent structural groups for every team specified, then nests them dynamically within the global environment root group.
  4. Instantiates a local service principal from the provided multi-tenant application, if one does not yet exist.
  5. Generates functional role groups (Marketer, Manager, Admin) under each team branch, extracts the true role UUIDs from the multi-tenantapplication manifest, and assigns them to the groups.

### 2. Validation (validate_deployment.sh)

Enforces structural integrity by checking critical components, hierarchy nesting, and app role assignments before returning a non-zero exit code upon detecting anomalies. 

### 3. Teardown (teardown_architecture.sh)

Safely reverses this deployment in chronological order by cleaning entitlement links, preventing orphans, and supporting native idempotency.

------------------------------
## 🛑 Automated Error Rollback
The script features an intelligent fail-safe routine. If any command fails, or if you manually interrupt execution using Ctrl+C:

* A trap intercepts the failure.
* The script reads a runtime history stack of created resources.
* It deletes all newly created groups in reverse chronological order.
* Your tenant is left completely clean, preventing partial, orphaned configurations.

------------------------------
## 🚀 Execution Instructions
### 1. Configure Your Environment File
Create or modify an environment file (e.g., dev.env, prod.env) in the root directory. Ensure all entries use valid structural configurations:
```
APP_ID="00000000-0000-0000-0000-000000000000"  # Multi-tenant App ID from CDS
ENV="Dev"                                      # Environment identifier
TEAMS=("Team1" "Team2" "Team3")                # Array of internal team names
```

### 2. Prepare the Scripts
Navigate to your working directory and mark the execution package as executable:

```chmod +x deploy_setup.sh validate_deployment.sh teardown_architecture.sh```

### 3. Run the Provisioning and Validation Pipeline
Execute the deployment script followed immediately by the validator script by passing your target configuration file as the first command-line argument.<br>
Using terminal chaining (&&) ensures the validation audit only runs if the initial setup succeeds:

```
./deploy_setup.sh dev.env && ./validate_deployment.sh dev.env
```

------------------------------
## 🗂️ Architecture Created
The script generates a multi-layered nested hierarchy. Given an environment of 'Dev' and a team named 'Sales', the structural outcome will look like this:

```text 
GCIV-AffinitiQuest-Dev-Users                      <- (Global Environment Root Group)
  └── GCIV-AffinitiQuest-Dev-Sales                <- (Team Parent Group)
        ├── GCIV-AffinitiQuest-Dev-Sales-Marketer <- (Assigned App Role: "Marketer")
        ├── GCIV-AffinitiQuest-Dev-Sales-Manager  <- (Assigned App Role: "Manager")
        └── GCIV-AffinitiQuest-Dev-Sales-Admin    <- (Assigned App Role: "Admin")
```

## 🗑️  Environment Teardown and Resource Purge
When an entire environment tier needs to be decommissioned or reset, run the teardown script with the corresponding configuration file.


### ⚠️ Warning: This will permanently delete the scoped Entra ID security groups for the targeted environment.
Running the script permanently deletes all scoped Entra ID security groups and app entitlements for the targeted environment. When executed, you must type the exact configuration filename (e.g., dev.env) at the interactive prompt to authorize the teardown.

```
./teardown_architecture.sh dev.env
```