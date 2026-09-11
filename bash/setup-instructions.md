## Entra ID Provisioning Guide: GCIV Affiniti Quest Teams
This script automates the creation and configuration of Microsoft Entra ID security groups, nested group architectures, app role assignments, and Microsoft Graph API permissions required for the GCIV Affiniti Quest service.
## 📋 Prerequisites
Before executing the script, ensure your local environment and identity meet the following requirements:

* Azure CLI: Must be installed and updated (az --version).
* Active Session: You must be actively logged into the correct tenant using az login.
* Entra ID Permissions: Your account requires the following privileged administrative roles:
    * Group Administrator (to create, delete, and nest security groups).
    * Application Administrator or Cloud Application Administrator (to grant API permissions and assign app roles).

------------------------------
## 🛠️ What the Script Does

   1. Validates the existence of your target App Registration via the provided Application ID.
   2. Creates a global root group for the target environment if it does not already exist: GCIV-AffinitiQuest-$ENV-Users.
   3. Provisions team parent groups for every team specified, then nests them cleanly inside the root environment group.
   4. Enforces an audit safety check ensuring newly targeted team names do not already contain existing, unexpected user memberships.
   5. Instantiates a Service Principal for your Application ID if one does not yet exist.
   6. Grants administrative Microsoft Graph API scopes required by the service application.
   7. Generates and links precise Role Groups (Marketer, Manager, Admin) for each team, mapping the matching Entra App Roles to those groups.

------------------------------
## 🛑 Automated Error Rollback
The script features an intelligent fail-safe routine. If any command fails, or if you manually interrupt execution using Ctrl+C:

* A trap intercepts the failure.
* The script reads a runtime history stack of created resources.
* It deletes all newly created groups in reverse chronological order.
* Your tenant is left completely clean, preventing partial, orphaned configurations.

------------------------------
## 🚀 Execution Instructions
## 1. Download and Prepare the Script
Save the script content to a local file, navigate to its directory, and make it executable:

```chmod +x setup.sh```

## 2. Execute the Automation
Run the script directly from your terminal:

```./setup.sh```

## 3. Provide Interactive Inputs
The script will pause to ask you for three vital parameters.

| Input Prompt | Example Entry | Description |
|---|---|---|
| Application ID | a1b2c3d4-e5f6-... | The Client/Application ID of the target App Registration provided by CDS. |
| Environment Name | Dev (or Staging, Prod) | Determines the naming convention and environment tracking context. |
| Team Name(s) | Alpha Bravo Charlie | Space-separated list of individual team names using the service. |

------------------------------
## 🗂️ Architecture Created
The script generates a multi-layered nested hierarchy. Given an environment of 'Dev' and a team named 'Sales', the structural outcome will look like this:

* GCIV-AffinitiQuest-Dev-Users (Global Root Environment Group)
  * GCIV-AffinitiQuest-Dev-Sales (Team Parent Group)
    * GCIV-AffinitiQuest-Dev-Sales-Marketer (Group assigned 'Marketer' App Role)
    * GCIV-AffinitiQuest-Dev-Sales-Manager  (Group assigned 'Manager' App Role)
    * GCIV-AffinitiQuest-Sev-Sales-Admin    (Group assigned 'Admin' App Role)



