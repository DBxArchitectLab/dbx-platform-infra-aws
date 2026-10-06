terraform {
  required_version = ">= 1.10.0"

  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}
