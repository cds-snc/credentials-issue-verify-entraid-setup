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

    # Store the exact path/filename globally for verification logic
    ACTIVE_ENV_FILE="$env_file"
}

# --- DEPENDENCY VERIFICATION ---
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' utility is required for execution but is missing." >&2
    exit 1
fi

# Invoke loader using fallback string interpolation to prevent empty-string argument overrides
load_environment_config "${1:-dev.env}"

# Architecture Constants
SECURITY_GROUP_PREFIX=GCIV-AffinitiQuest
AQ_ROLES=("Marketer" "Manager" "Admin")

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

echo "🔍 Configurations validated. Proceeding with Teardown..."
echo "Application ID: $APP_ID"
echo "Environment:    $ENV"
echo "Teams targeted: ${TEAMS[*]}"

# --- MANDATORY INTERACTIVE DELETION PROMPT ---

EXPECTED_CONFIRMATION=$(basename "$ACTIVE_ENV_FILE")
echo -e "\n⚠️  🛑  🚨 WARNING: RESOURCE DESTRUCTION RISK 🚨  🛑  ⚠️"
echo "You are running a teardown operation that will permanently delete all '$ENV' security groups and App Role mappings!"
echo -n "To confirm this action, please type the exact configuration filename '$EXPECTED_CONFIRMATION': "

# Read user input directly from the controlling terminal interface
read -r CONFIRMATION < /dev/tty

if [ "$CONFIRMATION" != "$EXPECTED_CONFIRMATION" ]; then
    echo "❌ Destruction aborted. Input mismatch (Expected: '$EXPECTED_CONFIRMATION', Received: '$CONFIRMATION')." >&2
    echo "No resources were changed."
    exit 1
fi
echo "✅ Confirmation verified. Initiating destruction phase..."

# Resolve Service Principal Object ID
set +e
SPN_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null)
set -e

# --- GLOBAL APP-ROLE ASSIGNMENTS CACHE ---
ASSIGNMENTS_CACHE_JSON="[]"
if [ -z "$SPN_ID" ]; then
    echo "⚠️ Warning: Local Service Principal instance not found for APP_ID $APP_ID."
    echo "App Role assignments cannot be audited natively, proceeding directly to group purging..."
else
    echo "📥 Fetching global App Role assignments cache..."
    # Downloads a minimal JSON map of assignments targeted only at this Enterprise App
    ASSIGNMENTS_CACHE_JSON=$(az ad approleassignment list --all --query "[?resourceId=='$SPN_ID'].{id:id, principalId:principalId}" -o json)
fi

TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))


# --- DESTRUCTION PHASE ---

# 1. Clean up Role-Specific Groups and App Role Assignments
echo -e "\n🧹 Deleting nested functional Role groups and App Role assignments..."
for TEAM in "${TEAMS_SET[@]}"; do
    for ROLE in "${AQ_ROLES[@]}"; do
        GROUP=$TEAM-$ROLE
        ROLE_GROUP_NAME="$SECURITY_GROUP_PREFIX-$ENV-$GROUP"
        
        echo "Processing role group: $ROLE_GROUP_NAME..."
        ROLE_GROUP_ID=$(az ad group list --filter "displayName eq '$ROLE_GROUP_NAME'" --query "[].id" -o tsv)
        
        if [ -n "$ROLE_GROUP_ID" ]; then
            # If SPN exists, use jq to parse local cache instead of hitting Azure API in a loop
            if [ -n "${SPN_ID:-}" ]; then
                echo "Parsing local cache for Group ID: $ROLE_GROUP_ID..."
                
                # JQ extracts assignment IDs matching the principal group ID directly out of RAM
                ASSIGNMENT_IDS=$(echo "$ASSIGNMENTS_CACHE_JSON" | jq -r ".[] | select(.principalId == \"$ROLE_GROUP_ID\") | .id")
                
                for ASSIGNMENT_ID in $ASSIGNMENT_IDS; do
                    echo "Removing App Role assignment: $ASSIGNMENT_ID..."
                    az ad approleassignment delete --id "$ASSIGNMENT_ID" || echo "   ⚠️ Failed to remove assignment."
                done
            fi
            
            # Delete the role group
            echo "🗑️ Deleting group..."
            az ad group delete --group "$ROLE_GROUP_ID"
            echo "✅ Successfully removed."
        else
            echo "ℹ️ Group does not exist. Skipping."
        fi
    done
done

# 2. Clean up Parent Team Groups
echo -e "\n🧹 Deleting parent Team security groups..."
for TEAM in "${TEAMS_SET[@]}"; do
    TEAM_GROUP_NAME="$SECURITY_GROUP_PREFIX-$ENV-$TEAM"
    
    echo "Processing team group: $TEAM_GROUP_NAME..."
    TEAM_GROUP_ID=$(az ad group list --filter "displayName eq '$TEAM_GROUP_NAME'" --query "[].id" -o tsv)
    
    if [ -n "$TEAM_GROUP_ID" ]; then
        echo "🗑️ Deleting group..."
        az ad group delete --group "$TEAM_GROUP_ID"
        echo "✅ Successfully removed."
    else
        echo "ℹ️ Group does not exist. Skipping."
    fi
done

# 3. Clean up Root Users Group
echo -e "\n🧹 Deleting root Users security group..."
AQ_USERS_GROUP="$SECURITY_GROUP_PREFIX-$ENV-Users"
AQ_USERS_GROUP_ID=$(az ad group list --filter "displayName eq '$AQ_USERS_GROUP'" --query "[].id" -o tsv)

if [ -n "$AQ_USERS_GROUP_ID" ]; then
    echo "Processing root group: $AQ_USERS_GROUP (ID: $AQ_USERS_GROUP_ID)..."
    echo "🗑️ Deleting root group..."
    az ad group delete --group "$AQ_USERS_GROUP_ID"
    echo "✅ Successfully removed."
else
    echo "ℹ️ Root group $AQ_USERS_GROUP does not exist. Skipping."
fi

echo -e "\n🎉 Teardown process completed successfully."
exit 0