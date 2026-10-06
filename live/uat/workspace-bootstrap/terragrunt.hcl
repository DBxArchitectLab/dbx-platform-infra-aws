include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "workspace" {
  config_path = "../workspace"

  mock_outputs = {
    workspace_id   = 1234567890123456
    workspace_url  = "https://dbc-00000000-0000.cloud.databricks.com"
    workspace_name = "dbw-dbx-architect-lab-uat"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

locals {
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  config = local.env.locals.config

  secret_scope_config      = yamldecode(file("${get_terragrunt_dir()}/secret-scope-config.yaml"))
  s3_config                = yamldecode(file("${get_terragrunt_dir()}/s3-storage-config.yaml"))
  catalog_config           = yamldecode(file("${get_terragrunt_dir()}/catalog-config.yaml"))
  external_location_config = yamldecode(file("${get_terragrunt_dir()}/external-location-config.yaml"))

  # Databricks service principal that runs the deployment (application ID). It's added to the catalog and
  # external location grants so Terraform keeps the access it needs to manage them.
  deploy_sp_application_id = get_env("DEPLOY_SP_APPLICATION_ID")
}

terraform {
  source = "../../../modules/workspace_bootstrap"
}

inputs = merge(
  local.env.inputs,
  {
    databricks_host = dependency.workspace.outputs.workspace_url
    workspace_id    = dependency.workspace.outputs.workspace_id

    region = local.config.region

    bucket_name          = "${local.s3_config.bucket.name_prefix}-${get_aws_account_id()}"
    bucket_force_destroy = try(local.s3_config.bucket.force_destroy, false)

    catalog_name             = local.catalog_config.catalog.name
    catalog_managed_prefix   = try(local.catalog_config.catalog.managed_prefix, "managed")
    enable_catalog_grants    = try(local.catalog_config.catalog.enable_grants, true)
    catalog_grant_principals = distinct(concat(local.catalog_config.catalog.grant_principals, [local.deploy_sp_application_id]))
    catalog_grant_privileges = try(local.catalog_config.catalog.grant_privileges, [
      "BROWSE",
      "USE_CATALOG",
      "CREATE_SCHEMA",
    ])

    external_location_name  = local.external_location_config.external_location.name
    storage_credential_name = try(local.external_location_config.external_location.storage_credential_name, null)
    uc_iam_role_name        = local.external_location_config.external_location.iam_role_name

    enable_external_location_grants    = try(local.external_location_config.external_location.enable_grants, true)
    external_location_owner            = try(local.external_location_config.external_location.owner, null)
    external_location_grant_principals = distinct(concat(local.external_location_config.external_location.grant_principals, [local.deploy_sp_application_id]))
    external_location_grant_privileges = try(local.external_location_config.external_location.grant_privileges, [
      "MANAGE",
      "READ_FILES",
      "WRITE_FILES",
      "CREATE_EXTERNAL_TABLE",
    ])

    secret_scope_name = local.secret_scope_config.secret_scope.name

    default_tags = merge(
      try(local.config.tags, {}),
      {
        Layer     = "workspace-bootstrap"
        Workspace = dependency.workspace.outputs.workspace_name
      }
    )

    cluster_policy_config_file = "${get_terragrunt_dir()}/cluster-policy-config.yaml"
    cluster_config_file        = "${get_terragrunt_dir()}/cluster-config.yaml"
    sql_warehouse_config_file  = "${get_terragrunt_dir()}/sql-warehouse-config.yaml"
  }
)
