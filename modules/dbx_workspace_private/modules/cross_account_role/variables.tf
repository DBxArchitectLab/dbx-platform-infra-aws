variable "databricks_account_id" {
  type = string
}

variable "role_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
