# Entra ID setup for GC Issue and Verify

Configures a partner's Entra ID to authenticate with an instance of GC Issue and Verify:
1. Creates a service principal for the Entra ID Application ID of the GC Issue and Verify instance.
2. Grants admin consent to the service principal for the needed Microsoft Graph APIs.
3. Creates security groups to assign permissions to users.
4. Assigns the GC Issue and Verify custom application roles to the security groups.

## Permissions needed

1. Application administrator
2. User administrator

## Managing users access to the GC Issue and Verify instance

Once the Entra ID setup has been successfully executed, you can manage user's access to the GC Issue and Verify instance by adding/removing them from the security groups with the application roles applied.

Each security group has one application role applied. The name of the security group matches the role applied to that security group. A user can only be in one security group as the application roles are mutually exclusive.

To give a user access to the GC Issue and Verify instance, add them to the security group for the role providing them the desired permissions.

To change a user's permissions in the GC Issue and Verify instance, remove them from the security group to which they are currently assigned and add them to the security group for the new role you want them to have.

To remove a user's access to the GC Issue and Verify instance, remove them for whatever security group they're a member of.
