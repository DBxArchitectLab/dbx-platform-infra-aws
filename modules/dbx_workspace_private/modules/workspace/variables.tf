variable "databricks_account_id" {
  type = string
}

variable "workspace_name" {
  type = string
}

variable "region" {
  type = string
}

variable "credentials_id" {
  type = string
}

variable "storage_configuration_id" {
  type = string
}

variable "network_id" {
  type = string
}

variable "private_access_settings_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
