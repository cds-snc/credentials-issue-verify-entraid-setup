resource "azuread_app_role_assignment" "AQRoleAssignment" {
	for_each			= { for role_group in local.role_groups : role_group.group => role_group }
	app_role_id			= azuread_service_principal.portal_app.app_role_ids[each.value.role]
	principal_object_id	= azuread_group.AQUserTeamRoleGroup[each.key].object_id
	resource_object_id	= azuread_service_principal.portal_app.object_id
}
