resource "azuread_service_principal" "portal_app" {
  client_id = var.portal_appID
  feature_tags {
    enterprise = true
    hide = false
  }
}
