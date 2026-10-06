output "workspace_id" {
  value = module.workspace.workspace_id
}

output "workspace_url" {
  value = module.workspace.workspace_url
}

output "workspace_name" {
  value = module.workspace.workspace_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_endpoint_ids" {
  value = module.network.vpc_endpoint_ids
}

output "cross_account_role_arn" {
  value = module.cross_account_role.role_arn
}

output "root_bucket_name" {
  value = module.root_storage.bucket_name
}
