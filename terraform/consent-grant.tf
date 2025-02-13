data "azuread_application_published_app_ids" "well_known" {}

resource "azuread_service_principal" "msgraph" {
	client_id		= data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph
	use_existing	= true
}

resource "azuread_service_principal_delegated_permission_grant" "portal_app_permissions" {
	service_principal_object_id				= azuread_service_principal.portal_app.object_id
	resource_service_principal_object_id	= azuread_service_principal.msgraph.object_id
	claim_values							= [ "openid", "profile", "User.Read" ]
}
