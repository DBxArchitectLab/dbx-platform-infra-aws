resource "databricks_metastore" "this" {
  provider = databricks.account

  name          = var.metastore_name
  storage_root  = var.storage_root
  region        = var.region
  force_destroy = var.force_destroy
  owner         = var.owner
}

resource "databricks_metastore_data_access" "default" {
  count = var.data_access_role_arn != null && var.data_access_role_arn != "" ? 1 : 0

  provider = databricks.account

  metastore_id = databricks_metastore.this.id
  name         = var.metastore_data_access_name

  aws_iam_role {
    role_arn = var.data_access_role_arn
  }

  is_default = true

  depends_on = [databricks_metastore.this]
}
