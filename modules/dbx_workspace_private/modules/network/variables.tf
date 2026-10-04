variable "databricks_account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Databricks requires subnets in at least two availability zones."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "One cluster subnet per availability zone (netmask between /17 and /26)."
}

variable "privatelink_subnet_cidrs" {
  type        = list(string)
  default     = []
  description = "One VPC endpoint subnet per availability zone. Used only when private_link_enabled."
}

variable "public_subnet_cidr" {
  type        = string
  default     = null
  description = "Small subnet for the NAT gateway. Used only when nat_gateway_enabled."
}

variable "nat_gateway_enabled" {
  type = bool
}

variable "private_link_enabled" {
  type = bool
}

variable "public_access_enabled" {
  type = bool
}

variable "workspace_vpce_service" {
  type    = string
  default = null
}

variable "relay_vpce_service" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
