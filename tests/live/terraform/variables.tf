variable "aws_region" {
  description = "AWS Region of the live run."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix of the live run, the same one the deploy target uses."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "Use 2-31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "cidr_block" {
  description = "CIDR block of the private VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones of the private subnets. Empty means the region's zones a and b."
  type        = list(string)
  default     = []
}

variable "interface_endpoints" {
  description = "Create the interface endpoints ECS tasks need to pull from ECR and write logs. make test-live runs no task and sets false."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags for every resource. The live scripts set purpose = portfolio-test."
  type        = map(string)
  default     = {}
}
