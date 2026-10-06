variable "databricks_account_id" {
  type = string
}

variable "metastore_name" {
  type = string
}

variable "region" {
  type        = string
  description = "AWS region for the metastore (e.g. us-east-2). Also used by the generated aws provider."
}

variable "storage_root" {
  type        = string
  default     = null
  description = "Optional s3:// URI for metastore-level managed storage. Leave null (recommended) so each catalog sets its own storage root."
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow Terraform to delete the metastore even if it is not empty."
}

variable "owner" {
  type        = string
  default     = null
  description = "Optional Unity Catalog owner for the metastore."
}

variable "metastore_data_access_name" {
  type        = string
  default     = "default"
  description = "Name for the default metastore data access configuration."
}

variable "data_access_role_arn" {
  type        = string
  default     = null
  description = "IAM role ARN for the metastore storage root (only needed with storage_root). Leave null to skip databricks_metastore_data_access."
}
