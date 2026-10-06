terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.account]
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
