#!/bin/bash

read -p "Enter Application ID: " APP_ID
read -p "Enter Environment Name: " ENV

#Update $TEAMS array with the names of each team that will be using the service
TEAMS=("Default" "team2")

#Turn $TEAMS array into a set to ensure each value is unique
TEAMS_SET=($(for v in "${TEAMS[@]}"; do echo "$v"; done | sort -u))

MS_GRAPH_ID=00000003-0000-0000-c000-000000000000
SECURITY_GROUP_PREFIX=GCIV-AffinitiQuest
AQ_USERS_GROUP="$SECURITY_GROUP_PREFIX-$ENV-Users"
AQ_ROLES=(
	"Marketer"
	"Manager"
	"Admin"
)

CLAIM_IDS=(
   37f7f235-527c-4136-accd-4a02d197296e
   14dad69e-099b-42c9-810b-d002981feec1
   e1fe6dd8-ba31-4d61-89e7-88639da4683d
   )

echo Creating service principal using provided APP_ID...
SPN_ID=az ad sp create --id $APP_ID --query "appId" -o tsv
echo Done.

echo Granting Microsoft Graph Permissions to App Registration...
az ad app permission grant --id $SPN_ID --api $MS_GRAPH_ID --scope "$CLAIM_IDS[0] $CLAIM_IDS[1] $CLAIM_IDS[2]"
echo Done.

# **TODO: pull list of existing groups and implement validation to only run command if group doesnt exist already**

# Iterate through TEAMS_SET and create security group for each TEAM, then iterate through AQ_ROLES and perform logic described below for each role
for TEAM in "${TEAMS_SET[@]}"; do

	AD_TEAM_GROUP="$SECURITY_GROUP_PREFIX-$ENV-$TEAM"

	echo Creating $AD_TEAM_GROUP security group...
	AD_TEAM_GROUP_ID=az ad group create --display-name $AD_TEAM_GROUP --security-enabled true --query "objectId" -o tsv
	echo Done.

	echo Adding $AD_TEAM_GROUP group to $AQ_USERS_GROUP group...
	az ad group member add --group $AQ_USERS_GROUP --member $AD_TEAM_GROUP_ID
	echo Done.

	# Iterate through AQ_ROLES and create required security groups as well as assign corresponding app role to each security group
	for ROLE in "${AQ_ROLES[@]}"; do

		GROUP=$TEAM-$ROLE
		AD_ROLE_GROUP="$SECURITY_GROUP_PREFIX-$ENV-$GROUP"

		echo Creating $AD_ROLE_GROUP security group in Entra ID...
		AD_ROLE_GROUP_ID=az ad group create --display-name $AD_ROLE_GROUP --security-enabled true --query "objectId" -o tsv
		echo Done.

		# Getting corresponding App Role ID for current $ROLE
		APP_ROLE_ID=az ad app show --id "$SPN_ID" --query "appRoles[?displayName == '$ROLE'].id" -o tsv

		# Assign corresponding app role to the group that we just created
		echo Assigning $ROLE app role to $AD_ROLE_GROUP group...
		az ad approleassignment create --principal-id "$AD_ROLE_GROUP_ID" --resource-id "$SPN_ID" --app-role-id "$APP_ROLE_ID"
		echo Done.

		# Alternate option for app role assignment using MSGraph API
		# 	az rest --method POST \
		# 		--uri "https://graph.microsoft.com/v1.0/groups/$AD_ROLE_GROUP_ID/appRoleAssignments" \
		# 		--headers "Content-Type=application/json" \
		# 		--body '{
		#     "principalId": "$AD_ROLE_GROUP_ID",
		#     "resourceId": "$SPN_ID",
		#     "appRoleId": "$APP_ROLE_ID"
		#   }'

		echo Adding $AD_ROLE_GROUP group to $AD_TEAM_GROUP group...
		az ad group member add --group $AD_TEAM_GROUP --member $AD_ROLE_GROUP_ID
		echo Done.

	done

done
