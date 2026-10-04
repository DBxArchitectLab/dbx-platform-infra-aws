output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "storage_configuration_id" {
  value = databricks_mws_storage_configurations.this.storage_configuration_id
}
