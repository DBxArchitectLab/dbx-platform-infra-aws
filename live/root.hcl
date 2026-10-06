locals {
  # Terraform state lives in an S3 bucket in the deployment AWS account. The account ID suffix keeps the
  # bucket name globally unique. Native S3 locking (use_lockfile) needs Terraform >= 1.10.
  state_bucket = "dbx-architect-lab-tfstate-${get_aws_account_id()}"
  state_region = "us-east-2"
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.generated.tf"
    if_exists = "overwrite"
  }

  config = {
    bucket       = local.state_bucket
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.state_region
    encrypt      = true
    use_lockfile = true
  }
}

generate "providers" {
  path      = "providers.generated.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "aws" {
  region = var.region
}

# Account-level provider. Authenticates as a Databricks service principal (OAuth M2M) using the
# DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET environment variables.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}
EOF
}
