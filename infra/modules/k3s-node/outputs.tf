output "instance_id" {
  description = "EC2 instance id."
  value       = aws_instance.node.id
}

output "public_ip" {
  description = "Public IP of the instance."
  value       = aws_instance.node.public_ip
}

output "private_ip" {
  description = "Private IP of the instance (used as the k3s server join address for HA peers)."
  value       = aws_instance.node.private_ip
}

output "security_group_id" {
  description = "Id of the node security group."
  value       = aws_security_group.node.id
}
