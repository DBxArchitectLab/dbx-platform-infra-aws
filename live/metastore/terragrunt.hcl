include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env    = read_terragrunt_config("${get_terragrunt_dir()}/env.hcl")
  config = local.env.locals.config
}

terraform {
  source = "../../modules/metastore"
}

inputs = merge(
  local.env.inputs,
  {
    metastore_name             = local.config.metastore.name
    region                     = local.config.metastore.region
    storage_root               = try(local.config.metastore.storage_root, null)
    force_destroy              = try(local.config.metastore.force_destroy, false)
    owner                      = try(local.config.metastore.owner, null)
    metastore_data_access_name = try(local.config.metastore.data_access_name, "default")
    data_access_role_arn       = try(local.config.metastore.data_access_role_arn, null)
  }
)
