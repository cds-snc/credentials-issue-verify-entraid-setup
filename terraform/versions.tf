terraform {
	required_providers {
		azuread = {
			source  = "hashicorp/azuread"
			version = "~> 3.1.0"
		}
		azurerm = {
			source  = "hashicorp/azurerm"
			version = "~> 4.17.0"
		}
	}
	required_version = "~> 1.10.0"
}
