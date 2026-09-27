terraform {
  # Same pins as infra/terraform, so one Terraform install covers every root.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project   = var.name
      ManagedBy = "terraform"
    })
  }
}
