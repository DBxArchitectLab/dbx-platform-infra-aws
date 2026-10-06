resource "databricks_mws_workspaces" "this" {
  provider = databricks.account

  account_id     = var.databricks_account_id
  workspace_name = var.workspace_name
  aws_region     = var.region

  credentials_id             = var.credentials_id
  storage_configuration_id   = var.storage_configuration_id
  network_id                 = var.network_id
  private_access_settings_id = var.private_access_settings_id

  custom_tags = var.tags
}
