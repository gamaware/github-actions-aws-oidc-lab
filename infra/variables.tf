variable "aws_region" {
  description = "AWS Region for every resource in this lab."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for the ECR repository, ECS cluster, service and roles."
  type        = string
  default     = "oidc-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "Use 2-31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository (the OWNER in OWNER/REPO)."
  type        = string
}

variable "github_repo" {
  description = "Repository name without the owner (the REPO in OWNER/REPO)."
  type        = string
}

variable "github_branch" {
  description = "The only branch whose workflows may assume the deploy role."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "The only GitHub environment whose jobs may assume the deploy role."
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set to false when the account already has one (only one per URL is allowed)."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC for the ECS service."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the ECS tasks. Private subnets need a NAT gateway or VPC endpoints to reach ECR."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Give tasks a public IP. Only needed in public subnets without NAT."
  type        = bool
  default     = false
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the container port. Empty means no inbound access."
  type        = list(string)
  default     = []
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of running tasks. Keep 0 until the first image is pushed, and between demos."
  type        = number
  default     = 0
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the container logs."
  type        = number
  default     = 365
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete the ECR repository while it still holds images."
  type        = bool
  default     = true
}
