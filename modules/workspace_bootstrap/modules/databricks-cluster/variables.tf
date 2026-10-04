variable "cluster_policy_ids" {
  description = "Map of Terraform-created cluster policy IDs"
  type        = map(string)
  default     = {}
}

variable "default_tags" {
  type    = map(string)
  default = {}
}

variable "clusters" {
  type = map(object({
    policy_name             = optional(string)
    spark_version           = optional(string)
    node_type_id            = optional(string)
    driver_node_type_id     = optional(string)
    autotermination_minutes = optional(number)
    num_workers             = optional(number)
    data_security_mode      = optional(string)
    runtime_engine          = optional(string)
    single_user_name        = optional(string)
    spark_conf              = optional(map(string))
    custom_tags             = optional(map(string))
    autoscale = optional(object({
      min_workers = number
      max_workers = number
    }))
    aws_attributes = optional(object({
      availability           = optional(string)
      first_on_demand        = optional(number)
      zone_id                = optional(string)
      spot_bid_price_percent = optional(number)
    }))
  }))
  default = {}
}