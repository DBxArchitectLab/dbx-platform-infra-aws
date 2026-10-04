variable "databricks_account_id" {
  type = string
}

variable "region" {
  type        = string
  description = "AWS region for the workspace and its VPC (e.g. us-east-1)."
}

variable "workspace_name" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type        = list(string)
  description = "At least two availability zones; one cluster subnet (and one PrivateLink subnet) is created in each."
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "privatelink_subnet_cidrs" {
  type    = list(string)
  default = []
}

variable "public_subnet_cidr" {
  type    = string
  default = null
}

variable "nat_gateway_enabled" {
  type        = bool
  default     = true
  description = "Create a NAT gateway so clusters can reach the internet (PyPI, Maven, external APIs)."
}

variable "private_link_enabled" {
  type        = bool
  default     = true
  description = "Back-end PrivateLink (REST API + secure cluster connectivity relay). Requires the Databricks Enterprise tier."
}

variable "public_access_enabled" {
  type        = bool
  default     = true
  description = "Allow access to the workspace from the public internet. Only applies when private_link_enabled."
}

variable "workspace_vpce_service" {
  type        = string
  default     = null
  description = "Regional Databricks workspace (REST API) VPC endpoint service name."
}

variable "relay_vpce_service" {
  type        = string
  default     = null
  description = "Regional Databricks secure cluster connectivity relay VPC endpoint service name."
}

variable "cross_account_role_name" {
  type = string
}

variable "root_bucket_name" {
  type = string
}

variable "root_bucket_force_destroy" {
  type    = bool
  default = false
}

variable "metastore_id" {
  type = string
}

variable "platform_admin_group_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
