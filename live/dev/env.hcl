locals {
  config = yamldecode(file("${get_terragrunt_dir()}/config.yaml"))
}

# Supplied as environment variables (GitHub environment secrets in CI).
inputs = {
  databricks_account_id = get_env("DATABRICKS_ACCOUNT_ID")
}
