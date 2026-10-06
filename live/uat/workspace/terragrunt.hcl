include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  config = local.env.locals.config
}

terraform {
  source = "../../../modules/dbx_workspace_private"
}

inputs = merge(
  local.env.inputs,
  {
    workspace_name = local.config.workspace_name
    region         = local.config.region

    cross_account_role_name   = local.config.cross_account_role_name
    root_bucket_name          = "${local.config.root_bucket.name_prefix}-${get_aws_account_id()}"
    root_bucket_force_destroy = try(local.config.root_bucket.force_destroy, false)

    vpc_name                 = local.config.network.vpc_name
    vpc_cidr                 = local.config.network.vpc_cidr
    availability_zones       = local.config.network.availability_zones
    private_subnet_cidrs     = local.config.network.private_subnet_cidrs
    privatelink_subnet_cidrs = try(local.config.network.privatelink_subnet_cidrs, [])
    public_subnet_cidr       = try(local.config.network.public_subnet_cidr, null)
    nat_gateway_enabled      = try(local.config.network.nat_gateway_enabled, true)

    private_link_enabled   = try(local.config.private_link.enabled, false)
    public_access_enabled  = try(local.config.private_link.public_access_enabled, true)
    workspace_vpce_service = try(local.config.private_link.workspace_vpce_service, null)
    relay_vpce_service     = try(local.config.private_link.relay_vpce_service, null)

    metastore_id              = get_env("DATABRICKS_METASTORE_ID")
    platform_admin_group_name = local.config.identity.platform_admin_group_name

    tags = local.config.tags
  }
)
