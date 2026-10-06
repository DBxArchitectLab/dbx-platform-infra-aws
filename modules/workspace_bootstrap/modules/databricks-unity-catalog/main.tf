locals {
  # Managed tables for this catalog; must be under an external location + credential (see workspace_bootstrap order).
  catalog_storage_root = "s3://${var.bucket_name}/${var.catalog_managed_prefix}/${var.catalog_name}/"
}

resource "databricks_catalog" "default" {
  name         = var.catalog_name
  comment      = "Default Unity Catalog bootstrap catalog."
  storage_root = local.catalog_storage_root

  # The metastore is shared by dev/uat/prod; without isolation the catalog shows up in every workspace.
  isolation_mode = "ISOLATED"
}

# Bind the catalog to this environment's workspace only.
resource "databricks_workspace_binding" "catalog" {
  securable_name = databricks_catalog.default.name
  securable_type = "catalog"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

resource "databricks_grants" "catalog" {
  count = var.enable_catalog_grants ? 1 : 0

  catalog = databricks_catalog.default.name

  dynamic "grant" {
    for_each = toset(var.catalog_grant_principals)
    content {
      principal  = grant.value
      privileges = var.catalog_grant_privileges
    }
  }

  depends_on = [databricks_catalog.default]
}
