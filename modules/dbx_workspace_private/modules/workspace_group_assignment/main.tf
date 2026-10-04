data "databricks_group" "platform_admin" {
  provider     = databricks.account
  display_name = var.platform_admin_group_name
}

resource "databricks_mws_permission_assignment" "platform_admin_workspace_admin" {
  provider     = databricks.account
  workspace_id = var.workspace_id
  principal_id = data.databricks_group.platform_admin.id
  permissions  = ["ADMIN"]
}