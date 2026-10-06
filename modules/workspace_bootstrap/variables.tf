variable "databricks_account_id" {
  description = "Databricks account ID (required by generated root account provider)"
  type        = string
}

variable "databricks_host" {
  description = "Workspace URL for workspace-level Databricks provider"
  type        = string
}

variable "workspace_id" {
  description = "ID of this environment's workspace; the catalog, external location and storage credential are bound to it only"
  type        = number
}

variable "region" {
  description = "AWS region for the S3 bucket and IAM role (e.g. us-east-2)"
  type        = string
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for the Unity Catalog external location and catalog managed storage"
  type        = string
}

variable "bucket_force_destroy" {
  description = "Allow Terraform to delete the bucket even if it still contains objects"
  type        = bool
  default     = false
}

variable "uc_iam_role_name" {
  description = "Name of the IAM role Unity Catalog assumes to access the bucket"
  type        = string
}

variable "catalog_name" {
  description = "Unity Catalog catalog name to create"
  type        = string
}

variable "catalog_managed_prefix" {
  description = "Path prefix inside the bucket for managed catalog data (separate from external location root)"
  type        = string
  default     = "managed"
}

variable "external_location_name" {
  description = "Unity Catalog external location name"
  type        = string
}

variable "storage_credential_name" {
  description = "Databricks storage credential name; if null, defaults to \"<external_location_name>_cred\""
  type        = string
  nullable    = true
  default     = null
}

variable "enable_external_location_grants" {
  description = "If true, apply databricks_grants on the external location for external_location_grant_principals."
  type        = bool
  default     = true
}

variable "external_location_grant_principals" {
  description = "Principals to grant external location privileges: group names, user emails, or service principal application IDs."
  type        = list(string)
}

variable "external_location_owner" {
  description = "Unity Catalog owner for the external location; null uses the first entry in external_location_grant_principals."
  type        = string
  nullable    = true
  default     = null
}

variable "external_location_grant_privileges" {
  description = "Unity Catalog privileges for the external location. MANAGE is required for Terraform to update the location in place (see external-location module comments)."
  type        = list(string)
  default = [
    "MANAGE",
    "READ_FILES",
    "WRITE_FILES",
    "CREATE_EXTERNAL_TABLE",
  ]
}

variable "enable_catalog_grants" {
  description = "If true, apply databricks_grants on the catalog for catalog_grant_principals."
  type        = bool
  default     = true
}

variable "catalog_grant_principals" {
  description = "Principals to grant catalog privileges: group names, user emails, or service principal application IDs."
  type        = list(string)
}

variable "catalog_grant_privileges" {
  description = "Catalog-level UC privileges only. Do not use CREATE_TABLE/CREATE_VIEW here (use schema grants)."
  type        = list(string)
  default = [
    "BROWSE",
    "USE_CATALOG",
    "CREATE_SCHEMA",
  ]
}

variable "secret_scope_name" {
  description = "Databricks secret scope name"
  type        = string
}

variable "default_tags" {
  description = "Common tags applied to supported bootstrap resources"
  type        = map(string)
  default     = {}
}

variable "cluster_policy_config_file" {
  description = "Path to cluster policy YAML config"
  type        = string
}

variable "cluster_config_file" {
  description = "Path to cluster YAML config"
  type        = string
}

variable "sql_warehouse_config_file" {
  description = "Path to SQL warehouse YAML config"
  type        = string
}
