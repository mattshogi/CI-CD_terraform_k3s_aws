output "server_public_ip" {
  value = aws_instance.k3s_server.public_ip
}
output "security_group_id" {
  value = aws_security_group.ec2_sg.id
}
output "subnet_id" {
  value = var.vpc_id != "" ? data.aws_subnet.existing[0].id : aws_subnet.public[0].id
}

output "nacl_id" {
  value       = var.vpc_id != "" ? "<existing-vpc-nacl-not-provided>" : aws_network_acl.public[0].id
  description = "Network ACL id for the created VPC, or placeholder when reusing an existing VPC."
}
