output "cluster_ids" {
  value = {
    for k, v in databricks_cluster.this : k => v.id
  }
}