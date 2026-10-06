locals {
  cluster_policy_config = yamldecode(file(var.cluster_policy_config_file))
  cluster_config        = yamldecode(file(var.cluster_config_file))
  sql_warehouse_config  = yamldecode(file(var.sql_warehouse_config_file))

  cluster_policies = try(local.cluster_policy_config.cluster_policies, {})
  clusters         = try(local.cluster_config.clusters, {})
  sql_warehouses   = try(local.sql_warehouse_config.sql_warehouses, {})
}