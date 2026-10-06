module "network" {
  source = "./modules/network"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id    = var.databricks_account_id
  region                   = var.region
  vpc_name                 = var.vpc_name
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = var.availability_zones
  private_subnet_cidrs     = var.private_subnet_cidrs
  privatelink_subnet_cidrs = var.privatelink_subnet_cidrs
  public_subnet_cidr       = var.public_subnet_cidr
  nat_gateway_enabled      = var.nat_gateway_enabled
  private_link_enabled     = var.private_link_enabled
  public_access_enabled    = var.public_access_enabled
  workspace_vpce_service   = var.workspace_vpce_service
  relay_vpce_service       = var.relay_vpce_service
  tags                     = var.tags
}

module "cross_account_role" {
  source = "./modules/cross_account_role"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id = var.databricks_account_id
  role_name             = var.cross_account_role_name
  tags                  = var.tags
}

module "root_storage" {
  source = "./modules/root_storage"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id = var.databricks_account_id
  bucket_name           = var.root_bucket_name
  force_destroy         = var.root_bucket_force_destroy
  tags                  = var.tags
}

module "workspace" {
  source = "./modules/workspace"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id      = var.databricks_account_id
  workspace_name             = var.workspace_name
  region                     = var.region
  credentials_id             = module.cross_account_role.credentials_id
  storage_configuration_id   = module.root_storage.storage_configuration_id
  network_id                 = module.network.network_id
  private_access_settings_id = module.network.private_access_settings_id
  tags                       = var.tags
}

module "metastore_assignment" {
  source = "./modules/metastore_assignment"

  providers = {
    databricks.account = databricks.account
  }

  workspace_id = module.workspace.workspace_id
  metastore_id = var.metastore_id
}

module "workspace_group_assignment" {
  source = "./modules/workspace_group_assignment"

  providers = {
    databricks.account = databricks.account
  }

  workspace_id              = module.workspace.workspace_id
  platform_admin_group_name = var.platform_admin_group_name

  # Account-level permission assignment needs identity federation, which Unity Catalog assignment enables.
  depends_on = [module.metastore_assignment]
}
