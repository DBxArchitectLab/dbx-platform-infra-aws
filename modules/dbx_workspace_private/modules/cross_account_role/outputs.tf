output "role_arn" {
  value = aws_iam_role.this.arn
}

output "credentials_id" {
  value = databricks_mws_credentials.this.credentials_id
}
