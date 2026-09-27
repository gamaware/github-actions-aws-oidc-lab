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

# The three GitHub names below end up inside StringEquals conditions. The
# validations refuse wildcard and separator characters, so a typo such as
# "*" cannot widen the trust policy (docs/adr/0001).
variable "github_owner" {
  description = "GitHub user or organization that owns the repository (the OWNER in OWNER/REPO)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_owner))
    error_message = "Use the exact owner name: letters, digits and hyphens only, no wildcards."
  }
}

variable "github_repo" {
  description = "Repository name without the owner (the REPO in OWNER/REPO)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.github_repo))
    error_message = "Use the exact repository name: letters, digits, '.', '_' and '-' only, no wildcards."
  }
}

variable "github_environment" {
  description = "The only GitHub environment whose jobs may assume the deploy role."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,255}$", var.github_environment))
    error_message = "Use the exact environment name: letters, digits, '.', '_' and '-' only, no wildcards."
  }
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

variable "create_plan_role" {
  description = "Create the read-only role that pull requests use to run terraform plan (docs/adr/0007)."
  type        = bool
  default     = false
}

variable "state_bucket" {
  description = "Name of the S3 bucket that holds this stack's state. Required when create_plan_role is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.create_plan_role || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket))
    error_message = "Set state_bucket to the state bucket name when create_plan_role is true."
  }
}

variable "state_key" {
  description = "Object key of this stack's state file in state_bucket."
  type        = string
  default     = "github-actions-aws-oidc-lab/terraform.tfstate"
}

variable "tags" {
  description = "Extra tags for every resource. make test-live sets purpose = portfolio-test."
  type        = map(string)
  default     = {}
}
