# Workspace root bucket (DBFS root, workspace system data).
resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Disabled"
  }
}

# Lets the Databricks control plane read and write the root bucket.
data "databricks_aws_bucket_policy" "this" {
  provider = databricks.account

  bucket                   = aws_s3_bucket.this.bucket
  databricks_e2_account_id = var.databricks_account_id
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.databricks_aws_bucket_policy.this.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "databricks_mws_storage_configurations" "this" {
  provider = databricks.account

  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.bucket_name}-storage"
  bucket_name                = aws_s3_bucket.this.bucket

  depends_on = [aws_s3_bucket_policy.this]
}
