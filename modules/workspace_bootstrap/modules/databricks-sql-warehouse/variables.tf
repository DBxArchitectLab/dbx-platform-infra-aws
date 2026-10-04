variable "default_tags" {
  type    = map(string)
  default = {}
}

variable "sql_warehouses" {
  type = map(object({
    cluster_size              = string
    min_num_clusters          = optional(number)
    max_num_clusters          = optional(number)
    auto_stop_mins            = optional(number)
    enable_serverless_compute = optional(bool)
    warehouse_type            = optional(string)
    spot_instance_policy      = optional(string)
    tags                      = optional(map(string))
  }))
  default = {}
}