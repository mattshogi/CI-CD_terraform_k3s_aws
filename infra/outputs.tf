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
