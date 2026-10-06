output "external_location_name" {
  value = databricks_external_location.this.name
}

output "external_location_url" {
  value = databricks_external_location.this.url
}

output "storage_credential_name" {
  value = databricks_storage_credential.this.name
}

output "iam_role_arn" {
  description = "IAM role Unity Catalog assumes to access the bucket."
  value       = aws_iam_role.this.arn
}
