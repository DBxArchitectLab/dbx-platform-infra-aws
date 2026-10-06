output "metastore_id" {
  description = "Unity Catalog metastore ID (UUID)."
  value       = databricks_metastore.this.id
}

output "metastore_name" {
  value = databricks_metastore.this.name
}
