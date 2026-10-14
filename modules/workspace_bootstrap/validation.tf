# Validation notebook, deployed to every environment's workspace. The notebook source is the same everywhere; the
# JSON file next to it holds this environment's expected values, taken from the same inputs and module outputs that
# provisioned the resources it checks.
locals {
  validation_notebook_path = "/Shared/platform/workspace-bootstrap-validation"

  validation_config = {
    environment    = try(var.default_tags.Environment, null)
    workspace_name = try(var.default_tags.Workspace, null)
    workspace_id   = var.workspace_id
    workspace_url  = var.databricks_host
    region         = var.region
    metastore_id   = var.metastore_id == null || var.metastore_id == "" ? null : var.metastore_id
    admin_group    = var.platform_admin_group_name

    catalog = {
      name             = module.unity_catalog.catalog_name
      storage_root     = module.unity_catalog.catalog_storage_root
      grant_principals = var.enable_catalog_grants ? var.catalog_grant_principals : []
      grant_privileges = var.catalog_grant_privileges
    }

    storage_credential = {
      name           = module.external_location.storage_credential_name
      isolation_mode = "ISOLATION_MODE_ISOLATED"
      iam_role_arn   = module.external_location.iam_role_arn
    }

    external_location = {
      name             = module.external_location.external_location_name
      url              = module.external_location.external_location_url
      isolation_mode   = "ISOLATION_MODE_ISOLATED"
      grant_principals = var.enable_external_location_grants ? var.external_location_grant_principals : []
      grant_privileges = var.external_location_grant_privileges
    }

    # Reachability test from the driver: the regional S3 endpoint (Unity Catalog data access, via the VPC's S3
    # gateway endpoint).
    storage_endpoint = "s3.${var.region}.amazonaws.com"

    cluster_policies = sort(keys(module.cluster_policy.cluster_policy_ids))
    secret_scope     = module.secret_scope.secret_scope_name
  }
}

# The config file references the module outputs above, so on destroy Terraform deletes it before the catalog,
# external location, storage credential, policies and secret scope it describes.
resource "databricks_workspace_file" "bootstrap_validation_config" {
  path           = "${local.validation_notebook_path}.json"
  content_base64 = base64encode(jsonencode(local.validation_config))
}

# Created after its config and deleted before it, so the notebook never exists without its expected values.
resource "databricks_notebook" "bootstrap_validation" {
  path   = local.validation_notebook_path
  source = "${path.module}/notebooks/workspace-bootstrap-validation.py"

  depends_on = [databricks_workspace_file.bootstrap_validation_config]
}
