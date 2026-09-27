variable "aws_region" {
  description = "AWS Region of the ECS service and ECR repository created by infra/terraform."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix used by infra/terraform. Pipeline resources are named <name>-pipeline, <name>-build and so on."
  type        = string
  default     = "oidc-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name))
    error_message = "Use 2-21 lowercase letters, digits or hyphens, starting with a letter (the connection name adds a suffix and allows 32 characters)."
  }
}

variable "tags" {
  description = "Extra tags for every resource, for example purpose = portfolio-test."
  type        = map(string)
  default     = {}
}

variable "source_type" {
  description = "codeconnections: a GitHub repository through AWS CodeConnections. s3: a zip in the artifact bucket, for demos and the live test."
  type        = string
  default     = "codeconnections"

  validation {
    condition     = contains(["codeconnections", "s3"], var.source_type)
    error_message = "Use codeconnections or s3."
  }
}

variable "github_repository" {
  description = "OWNER/REPO the connection reads from. Required when source_type is codeconnections."
  type        = string
  default     = ""

  validation {
    condition     = var.source_type != "codeconnections" || can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "Set github_repository to the exact OWNER/REPO when source_type is codeconnections."
  }
}

variable "source_branch" {
  description = "The only branch the pipeline builds and deploys."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]{1,255}$", var.source_branch))
    error_message = "Use the exact branch name, no wildcards."
  }
}

variable "source_object_key" {
  description = "Object key of the source zip in the artifact bucket when source_type is s3."
  type        = string
  default     = "source/source.zip"
}

variable "artifact_retention_days" {
  description = "Days before pipeline artifacts expire in the artifact bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.artifact_retention_days >= 1 && var.artifact_retention_days <= 365
    error_message = "Use 1 to 365 days."
  }
}

variable "artifact_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the artifact bucket while it still holds objects. make test-live-codepipeline sets it."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the CodeBuild logs."
  type        = number
  default     = 365
}

variable "app_url" {
  description = "Optional URL the Verify stage checks with GET /health. Empty skips the HTTP check."
  type        = string
  default     = ""
}

# The deploy target, from `terraform output` in infra/terraform.
variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the Build stage pushes to."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9._/-]+$", var.ecr_repository_arn))
    error_message = "Use the full ECR repository ARN."
  }
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9_-]+$", var.ecs_cluster_arn))
    error_message = "Use the full ECS cluster ARN."
  }
}

variable "ecs_service_arn" {
  description = "ARN of the ECS service the Deploy stage updates (service/<cluster>/<service>)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:service/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$", var.ecs_service_arn))
    error_message = "Use the full ECS service ARN in the service/<cluster>/<service> form."
  }
}

variable "execution_role_arn" {
  description = "ARN of the task execution role, the only role the pipeline may pass to ECS."
  type        = string
}

variable "task_definition_family" {
  description = "Task definition family the Deploy stage registers revisions in."
  type        = string
}
