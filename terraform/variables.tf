variable "portal_appID" {
	description = "Client (app) ID for the portal app in the CDS tenant"
	type		= string
	sensitive	= true
}

variable "environment" {
	description	= "Environment name"
	type		= string
	default		= "dev"
}

variable "security_group_prefix" {
	description = "Prefix for naming security groups"
	type = string
	default = "GCIV-AffinitiQuest"
}

variable "teams" {
	description = "List of teams using the environment"
	type		= list(string)
	default		= [
		"default"
	]
}
