resource "databricks_secret_scope" "this" {
  name = var.secret_scope_name
}
