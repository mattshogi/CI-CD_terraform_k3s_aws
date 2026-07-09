output "vpc_id" {
  description = "Id of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Id of the public subnet."
  value       = aws_subnet.public.id
}
