provider "databricks" {
  host = var.databricks_host

  # Authentication comes from the environment:
  # - CI and local service principal runs: DATABRICKS_CLIENT_ID / DATABRICKS_CLIENT_SECRET (OAuth M2M).
  # - Local user runs: `databricks auth login --host <workspace-url>` and DATABRICKS_AUTH_TYPE=databricks-cli.
}

module "s3_storage" {
  source = "./modules/s3-storage"

  bucket_name   = var.bucket_name
  force_destroy = var.bucket_force_destroy
  tags          = var.default_tags
}

module "external_location" {
  source = "./modules/databricks-external-location"

  workspace_id                       = var.workspace_id
  external_location_name             = var.external_location_name
  bucket_name                        = module.s3_storage.bucket_name
  storage_credential_name            = coalesce(var.storage_credential_name, "${var.external_location_name}_cred")
  iam_role_name                      = var.uc_iam_role_name
  enable_external_location_grants    = var.enable_external_location_grants
  external_location_grant_principals = var.external_location_grant_principals
  external_location_grant_privileges = var.external_location_grant_privileges
  external_location_owner            = var.external_location_owner
  tags                               = var.default_tags

  depends_on = [module.s3_storage]
}

module "unity_catalog" {
  source = "./modules/databricks-unity-catalog"

  workspace_id             = var.workspace_id
  catalog_name             = var.catalog_name
  bucket_name              = module.s3_storage.bucket_name
  catalog_managed_prefix   = var.catalog_managed_prefix
  enable_catalog_grants    = var.enable_catalog_grants
  catalog_grant_principals = var.catalog_grant_principals
  catalog_grant_privileges = var.catalog_grant_privileges

  depends_on = [module.external_location]
}

module "cluster_policy" {
  source = "./modules/databricks-cluster-policy"

  cluster_policies = local.cluster_policies
}

#module "cluster" {
#  source = "./modules/databricks-cluster"
#
#  clusters           = local.clusters
#  cluster_policy_ids = module.cluster_policy.cluster_policy_ids
#  default_tags       = var.default_tags
#}
#
#module "sql_warehouse" {
#  source = "./modules/databricks-sql-warehouse"
#
#  sql_warehouses = local.sql_warehouses
#  default_tags   = var.default_tags
#}

module "secret_scope" {
  source = "./modules/databricks-secret-scope"

  secret_scope_name = var.secret_scope_name
}
