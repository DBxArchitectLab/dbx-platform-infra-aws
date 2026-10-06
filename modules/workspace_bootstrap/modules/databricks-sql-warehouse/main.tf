resource "databricks_sql_endpoint" "this" {
  for_each = var.sql_warehouses

  name                      = each.key
  cluster_size              = each.value.cluster_size
  min_num_clusters          = try(each.value.min_num_clusters, 1)
  max_num_clusters          = try(each.value.max_num_clusters, 1)
  auto_stop_mins            = try(each.value.auto_stop_mins, 20)
  enable_serverless_compute = try(each.value.enable_serverless_compute, null)
  warehouse_type            = try(each.value.warehouse_type, "PRO")
  spot_instance_policy      = try(each.value.spot_instance_policy, "COST_OPTIMIZED")

  dynamic "tags" {
    for_each = [
      merge(var.default_tags, try(each.value.tags, {}))
    ]
    content {
      dynamic "custom_tags" {
        for_each = tags.value
        content {
          key   = custom_tags.key
          value = custom_tags.value
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = try(each.value.min_num_clusters, 1) <= try(each.value.max_num_clusters, 1)
      error_message = "SQL warehouse '${each.key}' must have min_num_clusters <= max_num_clusters."
    }
  }
}