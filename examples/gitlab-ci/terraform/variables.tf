variable "aws_region" {
  description = "AWS Region of the ECS service and ECR repository created by infra/terraform."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix used by infra/terraform. The GitLab role is named <name>-gitlab-deploy."
  type        = string
  default     = "oidc-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "Use 2-31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags for every resource, for example purpose = portfolio-test."
  type        = map(string)
  default     = {}
}

variable "gitlab_url" {
  description = "GitLab instance URL, the issuer of the ID tokens. https://gitlab.com or a self-managed URL."
  type        = string
  default     = "https://gitlab.com"

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.gitlab_url))
    error_message = "Use https://<host> with no path and no trailing slash."
  }
}

# Both values end up inside StringEquals conditions. The validations refuse
# wildcard and separator characters, so a typo cannot widen the trust policy.
variable "gitlab_project_path" {
  description = "Full project path, GROUP/PROJECT or GROUP/SUBGROUP/PROJECT."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$", var.gitlab_project_path))
    error_message = "Use the exact project path: letters, digits, '.', '_', '-' and '/' only, no wildcards."
  }
}

variable "gitlab_branch" {
  description = "The only branch whose jobs may assume the role. Make it a protected branch in GitLab."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]{1,255}$", var.gitlab_branch)) && !strcontains(var.gitlab_branch, ":")
    error_message = "Use the exact branch name, no wildcards."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitLab OIDC provider. Set to false when the account already has one for this URL."
  type        = bool
  default     = true
}

# The deploy target, from `terraform output` in infra/terraform. These values
# become IAM resources and conditions, so the validations refuse wildcards.
variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the pipeline pushes to."
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
  description = "ARN of the ECS service the pipeline updates."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:service/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$", var.ecs_service_arn))
    error_message = "Use the full ECS service ARN in the service/<cluster>/<service> form."
  }
}

variable "execution_role_arn" {
  description = "ARN of the task execution role, the only role the pipeline may pass to ECS."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.execution_role_arn))
    error_message = "Use the full execution role ARN, no wildcards."
  }
}

variable "task_definition_family" {
  description = "Task definition family the pipeline registers revisions in."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,255}$", var.task_definition_family))
    error_message = "Use the exact task definition family: letters, digits, '_' and '-' only, no wildcards."
  }
}
