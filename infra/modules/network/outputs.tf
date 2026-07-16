output "vpc_id" {
  description = "Id of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Id of the first public subnet (kept for single-node compatibility)."
  value       = aws_subnet.public[0].id
}

output "public_subnet_ids" {
  description = "Ids of all public subnets (one per AZ when availability_zones is set)."
  value       = aws_subnet.public[*].id
}
