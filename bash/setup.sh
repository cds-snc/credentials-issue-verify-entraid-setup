#!/bin/bash

# Exit immediately if a pipeline returns a non-zero status, and track errors in functions/traps
set -Eeuo pipefail

# ==========================================
#         SCRIPT CONFIGURATION
# ==========================================
# Replace these placeholder values with your static configurations
APP_ID="00000000-0000-0000-0000-000000000000" #ID of the multi-tenant application provided by CDS
ENV="dev" #Environment name (e.g., dev, test, prod)
TEAMS=("team1" "team2" "team3") #Array of internal teams to create security groups for. Add as many as needed.

# Microsoft Graph Constants
MS_GRAPH_ID=00000003-0000-0000-c000-000000000000
SECURITY_GROUP_PREFIX=GCIV-AffinitiQuest
DESCRIPTION="Group containing security groups for each team using the GCIV Affiniti Quest service"
AQ_ROLES=(
	"Marketer"
	"Manager"
	"Admin"
)

#Required Microsoft Graph API permissions for the service principal to function correctly.
CLAIM_IDS=(
   37f7f235-527c-4136-accd-4a02d197296e #openid (Allows users to sign in to the app with their work accounts).
   14dad69e-099b-42c9-810b-d002981feec1 #profile (Allows the app to read basic user profile information like name and photo).
   e1fe6dd8-ba31-4d61-89e7-88639da4683d #User.Read (Allows the user to sign in and lets the app read the profile of the signed-in user).
)

# Rollback Array - Keeps track of all Group IDs created during this execution
CREATED_GROUPS=()

# --- ERROR ROLLBACK FUNCTION ---
cleanup_on_failure() {
    local exit_code=$?
    # Only trigger rollback if an actual error or unexpected interruption occurred
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n\n🚨 [ROLLBACK] Script encountered an error (Exit Code: $exit_code) or was interrupted."
        if [ ${#CREATED_GROUPS[@]} -gt 0 ]; then
            echo "🧹 Cleaning up Entra ID resources created during this run..."
            # Delete in reverse order of creation to clean up sub-groups before parent groups cleanly
            for ((i=${#CREATED_GROUPS[@]}-1; i>=0; i--)); do
                local group_id="${CREATED_GROUPS[i]}"
                echo "🗑️ Deleting group ID: $group_id..."
                # Use || true to prevent the cleanup loop itself from crashing if a group is already gone
                az ad group delete --group "$group_id" || true
            done
            echo "✅ Rollback complete. Tenant cleaned."
        else
            echo "ℹ️ No resources were created yet. No cleanup required."
        fi
    fi
}

# Register the cleanup function to trigger on ERR (command failure), SIGINT (Ctrl+C), and SIGTERM (Termination)
trap cleanup_on_failure ERR SIGINT SIGTERM

# --- PRE-FLIGHT VALIDATION OF CONFIGURATION VARIABLES ---
if [ -z "${APP_ID:-}" ]; then
    echo "❌ Error: APP_ID configuration variable cannot be empty." >&2
    exit 1
fi
if [ -z "${ENV:-}" ]; then
    echo "❌ Error: ENV configuration variable cannot be empty." >&2
    exit 1
fi
if [ ${#TEAMS[@]} -eq 0 ]; then
    echo "❌ Error: TEAMS array configuration cannot be empty. Add at least one team." >&2
    exit 1
fi

echo "🔍 Configurations validated. Proceeding..."
echo "Application ID: $APP_ID"
echo "Environment:    $ENV"
echo "Teams targeted: ${TEAMS[*]}"

echo -e "\n🔍 Performing pre-flight check: Verifying Service Principal exists..."
# Turn off immediate exit temporary to check the command result status manually
set +e
SPN_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null)
set -e

if [ -z "$SPN_ID" ]; then
    echo "ℹ️ Service Principal not found. Attempting to instantiate the multi-tenant app in this tenant..."
    set +e
    SPN_ID=$(az ad sp create --id "$APP_ID" --query "id" -o tsv 2>/dev/null)
    set -e
    
    if [ -z "$SPN_ID" ]; then
        echo "❌ Error: The provided Application ID could not be found, and a Service Principal could not be created." >&2
        echo "Please ensure the external multi-tenant app has been granted admin consent in this tenant." >&2
        exit 1
    fi
fi
echo "✅ Service Principal verified successfully (Object ID: $SPN_ID)."

# Turn $TEAMS array into a set to ensure each value is unique
TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))

# Check if the $AQ_USERS_GROUP parent group exists 
AQ_USERS_GROUP="$SECURITY_GROUP_PREFIX-$ENV-Users"
AQ_USERS_GROUP_ID=$(az ad group list --filter "displayName eq '$AQ_USERS_GROUP'" --query "[].id" -o tsv)

if [ -z "$AQ_USERS_GROUP_ID" ]; then
    echo "Creating $AQ_USERS_GROUP group..."
    AQ_USERS_GROUP_ID=$(az ad group create \
        --display-name "$AQ_USERS_GROUP" \
		--mail-nickname "$AQ_USERS_GROUP" \
        --description "$DESCRIPTION" --query "id" -o tsv)
	CREATED_GROUPS+=("$AQ_USERS_GROUP_ID")
    echo "✅ Group created successfully. Proceeding..."
else
    echo "Group $AQ_USERS_GROUP already exists (ID: $AQ_USERS_GROUP_ID). Proceeding..."
fi

echo "Auditing and configuring team security groups..."
for TEAM in "${TEAMS_SET[@]}"; do
    TEAM_GROUP_NAME="$SECURITY_GROUP_PREFIX-$ENV-$TEAM"
    TEAM_DESCRIPTION="Parent security group containing AQ ROLE groups for members of the $TEAM_GROUP_NAME team"

    echo "Configuring AQ security group for $TEAM team..."
    TEAM_GROUP_ID=$(az ad group list --filter "displayName eq '$TEAM_GROUP_NAME'" --query "[].id" -o tsv)
    
    if [ -z "$TEAM_GROUP_ID" ]; then
        echo "Creating $TEAM_GROUP_NAME group..."
        TEAM_GROUP_ID=$(az ad group create \
            --display-name "$TEAM_GROUP_NAME" \
			--mail-nickname "$TEAM_GROUP_NAME" \
            --description "$TEAM_DESCRIPTION" --query "id" -o tsv)
			CREATED_GROUPS+=("$TEAM_GROUP_ID")
        echo "Done."
        echo "Adding new group to $AQ_USERS_GROUP..."
        az ad group member add --group "$AQ_USERS_GROUP_ID" --member "$TEAM_GROUP_ID"
        echo "Done."
    else
        echo "Existing security group found globally: (Name: $TEAM_GROUP_NAME)"

        # Check if $TEAM_GROUP_ID is a nested member of AQ_USERS_GROUP_ID
        IS_NESTED=$(az ad group member check --group "$AQ_USERS_GROUP_ID" --member-id "$TEAM_GROUP_ID" --query "value" -o tsv)
        if [ "$IS_NESTED" = "true" ]; then
            echo "Validated: $TEAM_GROUP_NAME is already an existing member of $AQ_USERS_GROUP. Skipping nesting..."
        else
            echo "Adding existing group ($TEAM_GROUP_NAME) to the $AQ_USERS_GROUP group..."
            az ad group member add --group "$AQ_USERS_GROUP_ID" --member "$TEAM_GROUP_ID"
            echo "Done."
        fi
        
        echo "Checking $TEAM_GROUP_NAME group for existing members..."
        if [ $(az ad group member list --group "$TEAM_GROUP_ID" --query "length(@)") -eq 0 ]; then
            echo "No existing members found inside $TEAM_GROUP_NAME, proceeding..."
        else
            echo "Error: $TEAM_GROUP_NAME group has existing members... Please try again with different team name" >&2
            exit 1
        fi
    fi
    echo "✅ Security group configuration for $TEAM complete. Proceeding..."
done
echo "✅ Security groups successfully configured for each team. Proceeding..." 

echo "Granting Microsoft Graph Permissions to Service Principal..."
az ad app permission grant --id "$SPN_ID" --api "$MS_GRAPH_ID" --scope "${CLAIM_IDS[@]}"
echo "✅ Done."

echo "Configuring AQ roles for each team..."
for TEAM in "${TEAMS_SET[@]}"; do

    TEAM_GROUP_ID=$(az ad group list --filter "displayName eq '$SECURITY_GROUP_PREFIX-$ENV-$TEAM'" --query "[].id" -o tsv)

    for ROLE in "${AQ_ROLES[@]}"; do
        GROUP=$TEAM-$ROLE
        ROLE_GROUP_NAME="$SECURITY_GROUP_PREFIX-$ENV-$GROUP"
        ROLE_DESCRIPTION="Security group for $ROLE users of the $SECURITY_GROUP_PREFIX service"

        echo "Creating $ROLE_GROUP_NAME security group..."
        ROLE_GROUP_ID=$(az ad group create \
                        --display-name "$ROLE_GROUP_NAME" \
						--mail-nickname "$GROUP" \
                        --description "$ROLE_DESCRIPTION" --query "id" -o tsv)
						CREATED_GROUPS+=("$ROLE_GROUP_ID")
        echo "✅ Done."

        # Extract the App Role ID directly from the local Service Principal object
        APP_ROLE_ID=$(az ad sp show --id "$APP_ID" --query "appRoles[?displayName == '$ROLE'].id" -o tsv)

        if [ -z "$APP_ROLE_ID" ]; then
            echo "❌ Error: App Role '$ROLE' could not be found on the multi-tenant application." >&2
            exit 1
        fi

        # Assign corresponding app role to the group that we just created
        echo "Assigning $ROLE app role to $ROLE_GROUP_NAME group..."
        az ad approleassignment create --principal-id "$ROLE_GROUP_ID" --resource-id "$SPN_ID" --app-role-id "$APP_ROLE_ID"
        echo "✅ Done."

        # Add role security group to the parent team security group
        echo "Adding $ROLE_GROUP_NAME group to parent team group..."
        az ad group member add --group "$TEAM_GROUP_ID" --member "$ROLE_GROUP_ID"
        echo "✅ Done."

	done
	echo "✅ All AQ roles for $TEAM team have been successfully configured. Proceeding..."
done

echo "✅ Setup completed successfully. Exiting."
exit 0
