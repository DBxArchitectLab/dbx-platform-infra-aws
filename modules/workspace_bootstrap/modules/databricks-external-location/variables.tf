variable "external_location_name" {
  description = "Unity Catalog external location name"
  type        = string
}

variable "external_location_owner" {
  description = "Unity Catalog owner (user, group, or service principal id). Defaults to the first entry in external_location_grant_principals. The Terraform identity should be this user, a member of this group, or metastore admin."
  type        = string
  nullable    = true
  default     = null
}

variable "bucket_name" {
  description = "S3 bucket used as the external location root"
  type        = string
}

variable "storage_credential_name" {
  description = "Databricks storage credential name"
  type        = string
}

variable "iam_role_name" {
  description = "Name of the IAM role Unity Catalog assumes to access the bucket (created by this module)"
  type        = string
}

variable "enable_external_location_grants" {
  description = "If true, apply databricks_grants on the external location for external_location_grant_principals."
  type        = bool
  default     = true
}

variable "external_location_grant_principals" {
  description = "Principals to receive privileges on the external location: group names, user emails, or service principal application IDs. The first entry is the default owner."
  type        = list(string)

  validation {
    condition     = length(var.external_location_grant_principals) > 0
    error_message = "external_location_grant_principals must contain at least one principal."
  }
}

variable "external_location_grant_privileges" {
  description = "Unity Catalog privileges for EXTERNAL_LOCATION. Include MANAGE so the grant principals (and the Terraform runner, if it is one of them or in one of those groups) can update the location; omit MANAGE in production if you restrict who may alter locations."
  type        = list(string)
  default = [
    "MANAGE",
    "READ_FILES",
    "WRITE_FILES",
    "CREATE_EXTERNAL_TABLE",
  ]
}

variable "tags" {
  description = "Tags applied to the IAM role."
  type        = map(string)
  default     = {}
}
