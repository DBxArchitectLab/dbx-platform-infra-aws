variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name."
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow Terraform to delete the bucket even if it still contains objects."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the bucket."
}
