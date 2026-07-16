output "dns_name" {
  description = "Public DNS name of the network load balancer (stable web endpoint for the HA cluster)."
  value       = aws_lb.this.dns_name
}
