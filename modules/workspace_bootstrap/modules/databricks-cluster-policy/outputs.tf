output "cluster_policy_ids" {
  value = {
    for k, v in databricks_cluster_policy.this : k => v.id
  }
}