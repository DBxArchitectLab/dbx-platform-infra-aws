output "sql_warehouse_ids" {
  value = {
    for k, v in databricks_sql_endpoint.this : k => v.id
  }
}