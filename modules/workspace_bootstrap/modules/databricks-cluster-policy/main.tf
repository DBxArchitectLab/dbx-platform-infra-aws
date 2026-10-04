resource "databricks_cluster_policy" "this" {
  for_each = var.cluster_policies

  name        = each.key
  description = try(each.value.description, null)
  definition  = jsonencode(each.value.definition)
}