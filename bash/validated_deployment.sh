#!/bin/bash

set -Eeuo pipefail

# Match loader architecture mapping
load_environment_config() {
    local env_file="${1:-dev.env}"
    if [ ! -f "$env_file" ]; then
        echo "❌ Error: Configuration file '$env_file' not found." >&2
        exit 1
    fi
    source "$env_file"
}

load_environment_config "${1:-dev.env}"

SECURITY_GROUP_PREFIX="GCIV-AffinitiQuest"
AQ_ROLES=("Marketer" "Manager" "Admin")
FAILED_CHECKS=0

echo "🧪 Commencing Post-Deployment Validation Engine Audit..."

SPN_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv 2>/dev/null || echo "")
if [ -z "$SPN_ID" ]; then
    echo "❌ CRITICAL: Service Principal for App ID $APP_ID is completely missing." >&2
    exit 1
fi

AQ_USERS_GROUP="${SECURITY_GROUP_PREFIX}-${ENV}-Users"
AQ_USERS_GROUP_ID=$(az ad group list --filter "displayName eq '$AQ_USERS_GROUP'" --query "[].id" -o tsv)
if [ -z "$AQ_USERS_GROUP_ID" ]; then
    echo "❌ CRITICAL: Global Root Group '$AQ_USERS_GROUP' was not found!" >&2
    exit 1
fi

TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))

for TEAM in "${TEAMS_SET[@]}"; do
    TEAM_GROUP_NAME="${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}"
    echo -e "\n📁 Testing Path: $TEAM_GROUP_NAME"
    
    TEAM_GROUP_ID=$(az ad group list --filter "displayName eq '$TEAM_GROUP_NAME'" --query "[].id" -o tsv)
    if [ -z "$TEAM_GROUP_ID" ]; then
        echo "   ❌ ERROR: Target parent structural group missing." >&2
        ((FAILED_CHECKS++))
        continue
    fi

    IS_IN_USERS=$(az ad group member check --group "$AQ_USERS_GROUP_ID" --member-id "$TEAM_GROUP_ID" --query "value" -o tsv)
    if [ "$IS_IN_USERS" != "true" ]; then
        echo "   ❌ ERROR: Hierarchy nesting constraint fault inside Root Users group." >&2
        ((FAILED_CHECKS++))
    fi

    for ROLE in "${AQ_ROLES[@]}"; do
        ROLE_GROUP_NAME="${SECURITY_GROUP_PREFIX}-${ENV}-${TEAM}-${ROLE}"
        ROLE_GROUP_ID=$(az ad group list --filter "displayName eq '$ROLE_GROUP_NAME'" --query "[].id" -o tsv)
        
        if [ -z "$ROLE_GROUP_ID" ]; then
            echo "   ❌ ERROR: Functional group '$ROLE_GROUP_NAME' does not exist." >&2
            ((FAILED_CHECKS++))
            continue
        fi

        IS_IN_TEAM=$(az ad group member check --group "$TEAM_GROUP_ID" --member-id "$ROLE_GROUP_ID" --query "value" -o tsv)
        if [ "$IS_IN_TEAM" != "true" ]; then
            echo "      ❌ ERROR: Functional role group is detached from team branch grouping." >&2
            ((FAILED_CHECKS++))
        fi

        APP_ROLE_ID=$(az ad sp show --id "$APP_ID" --query "appRoles[?displayName == '$ROLE'].id" -o tsv)
        HAS_ASSIGNMENT=$(az ad approleassignment list --id "$SPN_ID" \
            --query "[?principalId=='$ROLE_GROUP_ID' && appRoleId=='$APP_ROLE_ID']" -o tsv)

        if [ -z "$HAS_ASSIGNMENT" ]; then
            echo "      ❌ ERROR: Enterprise role asset mapping link definition is completely unassigned!" >&2
            ((FAILED_CHECKS++))
        else
            echo "      ✅ Role '${ROLE}' linked correctly."
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
