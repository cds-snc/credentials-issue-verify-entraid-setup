#!/bin/bash

set -Eeuo pipefail

# --- Central Config Loader Function ---
load_environment_config() {
    local env_file="${1:-dev.env}"
    if [ ! -f "$env_file" ]; then
        echo "❌ Error: Configuration file '$env_file' not found." >&2
        exit 1
    fi
    echo "📂 Loading environment variables from: $env_file"
    source "$env_file"
}

# --- DEPENDENCY VERIFICATION ---
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' utility is required for execution but is missing." >&2
    exit 1
fi

load_environment_config "${1:-dev.env}"

SECURITY_GROUP_PREFIX="GCIV-AffinitiQuest"
AQ_ROLES=("Marketer" "Manager" "Admin")
FAILED_CHECKS=0

echo "🧪 Commencing Post-Deployment Validation Engine Audit..."

# 1. Resolve and Validate Core Infrastructure Components
SPN_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null || echo "")
if [ -z "$SPN_ID" ]; then
    echo "❌ CRITICAL: Service Principal for App ID $APP_ID is missing." >&2
    exit 1
fi

AQ_USERS_GROUP="${SECURITY_GROUP_PREFIX}-${ENV}-Users"
AQ_USERS_GROUP_ID=$(az ad group list --filter "displayName eq '$AQ_USERS_GROUP'" --query "[].id" -o tsv)
if [ -z "$AQ_USERS_GROUP_ID" ]; then
    echo "❌ CRITICAL: Global Root Group '$AQ_USERS_GROUP' was not found!" >&2
    exit 1
fi

# 2. Build Global Data Caches to Eliminate Loop API Overhead
echo "📥 Fetching global App Role assignments cache..."
APP_ROLES_JSON=$(az ad sp show --id "$APP_ID" --query "appRoles" -o json)
ASSIGNMENTS_CACHE_JSON=$(az ad approleassignment list --all --query "[?resourceId=='$SPN_ID'].{appRoleId:appRoleId, principalId:principalId}" -o json)

echo "📥 Fetching group directory structures cache..."
# Fetches all relevant group metadata in one query to verify nested hierarchies locally
ALL_GROUPS_JSON=$(az ad group list --filter "startsWith(displayName, '$SECURITY_GROUP_PREFIX-$ENV')" --query "[].{id:id, displayName:displayName}" -o json)

TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))

# 3. Validation Matrix Checks
for TEAM in "${TEAMS_SET[@]}"; do
    TEAM_GROUP_NAME="${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}"
    echo -e "\n📁 Testing Path: $TEAM_GROUP_NAME"
    
    # Check parent group existence via local JSON cache
    TEAM_GROUP_ID=$(echo "$ALL_GROUPS_JSON" | jq -r ".[] | select(.displayName == \"$TEAM_GROUP_NAME\") | .id")
    if [ -z "$TEAM_GROUP_ID" ]; then
        echo "❌ ERROR: Target parent structural group missing." >&2
        ((FAILED_CHECKS++))
        continue
    fi

    # Check hierarchy nesting link via API (requires live lookup since check is a unique query endpoint)
    IS_IN_USERS=$(az ad group member check --group "$AQ_USERS_GROUP_ID" --member-id "$TEAM_GROUP_ID" --query "value" -o tsv)
    if [ "$IS_IN_USERS" != "true" ]; then
        echo "❌ ERROR: Hierarchy nesting constraint fault inside Root Users group." >&2
        ((FAILED_CHECKS++))
    fi

    for ROLE in "${AQ_ROLES[@]}"; do
        ROLE_GROUP_NAME="${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}-${ROLE}"
        
        # Verify functional role group existence in cache
        ROLE_GROUP_ID=$(echo "$ALL_GROUPS_JSON" | jq -r ".[] | select(.displayName == \"$ROLE_GROUP_NAME\") | .id")
        if [ -z "$ROLE_GROUP_ID" ]; then
            echo "❌ ERROR: Functional group '$ROLE_GROUP_NAME' does not exist." >&2
            ((FAILED_CHECKS++))
            continue
        fi

        # Check sub-nesting membership attachment link
        IS_IN_TEAM=$(az ad group member check --group "$TEAM_GROUP_ID" --member-id "$ROLE_GROUP_ID" --query "value" -o tsv)
        if [ "$IS_IN_TEAM" != "true" ]; then
            echo "❌ ERROR: Functional role group is detached from team branch grouping." >&2
            ((FAILED_CHECKS++))
        fi

        # Parse App Role ID locally using JQ
        APP_ROLE_ID=$(echo "$APP_ROLES_JSON" | jq -r ".[] | select(.displayName == \"$ROLE\") | .id")
        if [ -z "$APP_ROLE_ID" ] || [ "$APP_ROLE_ID" == "null" ]; then
            echo "❌ ERROR: Custom role '${ROLE}' manifest definition missing from Enterprise App!" >&2
            ((FAILED_CHECKS++))
            continue
        fi

        # Check app role assignment linkage against local JSON cache
        HAS_ASSIGNMENT=$(echo "$ASSIGNMENTS_CACHE_JSON" | jq -r ".[] | select(.principalId == \"$ROLE_GROUP_ID\" and .appRoleId == \"$APP_ROLE_ID\") | .appRoleId")

        if [ -z "$HAS_ASSIGNMENT" ]; then
            echo "❌ ERROR: Enterprise role asset mapping link definition is completely unassigned!" >&2
            ((FAILED_CHECKS++))
        else
            echo "✅ Role '${ROLE}' linked correctly."
        fi
    done
done

echo -e "\n=========================================="
if [ "$FAILED_CHECKS" -eq 0 ]; then
    echo "🎉 SUCCESS: All environment assets deploy, nest, and bind completely clean!"
    exit 0
else
    echo "🚨 FAILURE: Validation run concluded with $FAILED_CHECKS architectural validation failures." >&2
    exit 1
fi
