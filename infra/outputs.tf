output "server_public_ip" {
  description = "Public IP of the k3s server."
  value       = module.k3s_server.public_ip
}

output "server_instance_id" {
  description = "Instance id of the k3s server (use with `aws ssm start-session --target`)."
  value       = module.k3s_server.instance_id
}

output "security_group_id" {
  description = "Security group protecting the k3s server."
  value       = module.k3s_server.security_group_id
}

output "subnet_id" {
  description = "Subnet the server was launched into."
  value       = local.subnet_id
}

output "grafana_password_ssm_parameter" {
  description = "SSM Parameter Store name holding the Grafana admin password (when monitoring is enabled)."
  value       = var.enable_monitoring ? aws_ssm_parameter.grafana_admin_password[0].name : null
}

output "endpoint_host" {
  description = "Stable host to validate against: the NLB DNS name in HA mode, otherwise the primary node's public IP."
  value       = var.ha_mode ? module.nlb[0].dns_name : module.k3s_server.public_ip
}

output "server_instance_ids" {
  description = "Instance ids of all k3s server nodes (primary first, then any HA peers)."
  value       = concat([module.k3s_server.instance_id], module.k3s_joiners[*].instance_id)
}

output "ha_mode" {
  description = "Whether the cluster was deployed in high-availability mode."
  value       = var.ha_mode
}
