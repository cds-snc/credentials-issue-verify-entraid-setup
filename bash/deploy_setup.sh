#!/bin/bash

# Exit immediately on failure, track errors in sub-shells/functions
set -Eeuo pipefail

# --- Central Config Loader Function ---
load_environment_config() {
    # Check if an environment file argument was provided, default to dev.env
    local env_file="${1:-dev.env}"
    
    if [ ! -f "$env_file" ]; then
        echo "❌ Error: Configuration file '$env_file' not found." >&2
        echo "Usage: $0 [path/to/environment.env]" >&2
        exit 1
    fi
    
    echo "📂 Loading environment variables from: $env_file"
    source "$env_file"
}

# Invoke loader using passed argument
load_environment_config "${1:-dev.env}"

# Architecture Constants
SECURITY_GROUP_PREFIX=GCIV-AffinitiQuest
DESCRIPTION="Group containing security groups for each team using the GCIV Affiniti Quest service"
AQ_ROLES=("Marketer" "Manager" "Admin")
CREATED_GROUPS=()

# --- ERROR ROLLBACK FUNCTION ---
cleanup_on_failure() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n\n🚨 [ROLLBACK] Script encountered an error (Exit Code: $exit_code) or was interrupted."
        if [ ${#CREATED_GROUPS[@]} -gt 0 ]; then
            echo "🧹 Cleaning up Entra ID resources created during this run..."
            for ((i=${#CREATED_GROUPS[@]}-1; i>=0; i--)); do
                local group_id="${CREATED_GROUPS[i]}"
                echo "🗑️ Deleting group ID: $group_id..."
                az ad group delete --group "$group_id" || true
            done
            echo "✅ Rollback complete. Tenant cleaned."
        else
            echo "ℹ️ No resources were created yet. No cleanup required."
        fi
    fi
}

trap cleanup_on_failure ERR SIGINT SIGTERM

# --- PRE-FLIGHT VALIDATION ---
UUID_REGEX="^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
if [[ ! "${APP_ID:-}" =~ $UUID_REGEX ]]; then
    echo "❌ Error: APP_ID must be a valid 36-character UUID" >&2
    exit 1
fi
if [ -z "${ENV:-}" ]; then
    echo "❌ Error: ENV identifier string cannot be empty." >&2
    exit 1
fi
if [ ${#TEAMS[@]} -eq 0 ]; then
    echo "❌ Error: TEAMS array configuration cannot be empty." >&2
    exit 1
fi

echo "🔍 Configurations validated. Proceeding..."
echo "Application ID: $APP_ID"
echo "Environment:    $ENV"
echo "Teams targeted: ${TEAMS[*]}"

echo -e "\n🔍 Verifying local Service Principal instance exists..."
set +e
SPN_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null)
set -e

if [ -z "$SPN_ID" ]; then
    echo "ℹ️ Service Principal not found. Instantiating multi-tenant app locally..."
    set +e
    SPN_ID=$(az ad sp create --id "$APP_ID" --query "id" -o tsv 2>/dev/null)
    set -e
    
    if [ -z "$SPN_ID" ]; then
        echo "❌ Error: The provided Application ID could not be found or instantiated." >&2
        exit 1
    fi
fi
echo "✅ Service Principal verified successfully (Object ID: $SPN_ID)."

TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))

# Verify or Create global root group
AQ_USERS_GROUP="$SECURITY_GROUP_PREFIX-$ENV-Users"
AQ_USERS_GROUP_ID=$(az ad group list --filter "displayName eq '$AQ_USERS_GROUP'" --query "[].id" -o tsv)

if [ -z "$AQ_USERS_GROUP_ID" ]; then
    echo "Creating root group: $AQ_USERS_GROUP..."
    AQ_USERS_GROUP_ID=$(az ad group create \
        --display-name "$AQ_USERS_GROUP" \
        --mail-nickname "$AQ_USERS_GROUP" \
        --description "$DESCRIPTION" --query "id" -o tsv)
    CREATED_GROUPS+=("$AQ_USERS_GROUP_ID")
    echo "✅ Group created successfully."
else
    echo "Root group $AQ_USERS_GROUP already exists (ID: $AQ_USERS_GROUP_ID)."
fi

# Audit and provision team groupings
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
        
        az ad group member add --group "$AQ_USERS_GROUP_ID" --member "$TEAM_GROUP_ID"
    else
        echo "Existing security group found: $TEAM_GROUP_NAME"
        IS_NESTED=$(az ad group member check --group "$AQ_USERS_GROUP_ID" --member-id "$TEAM_GROUP_ID" --query "value" -o tsv)
        if [ "$IS_NESTED" != "true" ]; then
            az ad group member add --group "$AQ_USERS_GROUP_ID" --member "$TEAM_GROUP_ID"
        fi
        
        if [ $(az ad group member list --group "$TEAM_GROUP_ID" --query "length(@)") -ne 0 ]; then
            echo "Error: $TEAM_GROUP_NAME group contains pre-existing members... Aborting setup." >&2
            exit 1
        fi
    fi
done

# Map custom functional roles
echo -e "\n🏗️ Building functional App Role nested matrix structures..."
for TEAM in "${TEAMS_SET[@]}"; do
    TEAM_GROUP_ID=$(az ad group list --filter "displayName eq '$SECURITY_GROUP_PREFIX-$ENV-$TEAM'" --query "[].id" -o tsv)

    for ROLE in "${AQ_ROLES[@]}"; do
        GROUP=$TEAM-$ROLE
        ROLE_GROUP_NAME="$SECURITY_GROUP_PREFIX-$ENV-$GROUP"
        ROLE_DESCRIPTION="Security group for $ROLE users of the $SECURITY_GROUP_PREFIX service"

        echo "Creating functional mapping: $ROLE_GROUP_NAME..."
        ROLE_GROUP_ID=$(az ad group create \
                        --display-name "$ROLE_GROUP_NAME" \
                        --mail-nickname "$GROUP" \
                        --description "$ROLE_DESCRIPTION" --query "id" -o tsv)
        CREATED_GROUPS+=("$ROLE_GROUP_ID")

        # Pull App Role UUID straight out of the Enterprise App Instance
        APP_ROLE_ID=$(az ad sp show --id "$APP_ID" --query "appRoles[?displayName == '$ROLE'].id" -o tsv)

        if [ -z "$APP_ROLE_ID" ]; then
            echo "❌ Error: Custom role '$ROLE' does not exist in the source application definition manifest." >&2
            exit 1
        fi

        # Execute assignment and link memberships together
        az ad approleassignment create --principal-id "$ROLE_GROUP_ID" --resource-id "$SPN_ID" --app-role-id "$APP_ROLE_ID"
        az ad group member add --group "$TEAM_GROUP_ID" --member "$ROLE_GROUP_ID"
        echo "   ✅ Completed mapping successfully."
    done
done

echo "✅ Deployment processing completed successfully."
exit 0
