locals {
	AQRoles = [
		"Admin",
		"Manager",
		"Marketer"
	]
}

locals {
	role_groups = flatten([
		for team in var.teams:[
			for role in local.AQRoles: {
				team = team
				role = role
				group = "${team}-${role}"
			}
		]
	])
}
