output "vpc_id" {
  description = "The private VPC, for the deploy target's vpc_id."
  value       = aws_vpc.live.id
}

output "subnet_ids" {
  description = "The private subnets, for the deploy target's subnet_ids."
  value       = aws_subnet.private[*].id
}
