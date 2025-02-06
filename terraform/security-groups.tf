resource "azuread_group" "AQUserTeamRoleGroup" {
	for_each			= { for role_group in local.role_groups : role_group.group => role_group }
	display_name		= "${var.security_group_prefix}-${var.environment}-${each.key}"
	security_enabled	= true
}

resource "azuread_group" "AQUserTeamGroup" {
	for_each			= toset(var.teams)
	display_name		= "${var.security_group_prefix}-${var.environment}-${each.key}"
	security_enabled 	= true
	members				= values(azuread_group.AQUserTeamRoleGroup)[*].object_id
}

resource "azuread_group" "AQUsers" {
	display_name		= "${var.security_group_prefix}-${var.environment}-Users"
	security_enabled	= true
	members				= values(azuread_group.AQUserTeamGroup)[*].object_id
}
