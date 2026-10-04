output "catalog_id" {
  value = databricks_catalog.default.id
}

output "catalog_name" {
  value = databricks_catalog.default.name
}

output "catalog_storage_root" {
  value = local.catalog_storage_root
}
