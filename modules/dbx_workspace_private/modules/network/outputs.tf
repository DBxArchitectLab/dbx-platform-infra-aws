output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "security_group_id" {
  value = aws_security_group.workspace.id
}

output "network_id" {
  value = databricks_mws_networks.this.network_id
}

output "private_access_settings_id" {
  value = var.private_link_enabled ? databricks_mws_private_access_settings.this[0].private_access_settings_id : null
}

output "vpc_endpoint_ids" {
  value = {
    s3        = aws_vpc_endpoint.s3.id
    workspace = try(aws_vpc_endpoint.workspace[0].id, null)
    relay     = try(aws_vpc_endpoint.relay[0].id, null)
  }
}
