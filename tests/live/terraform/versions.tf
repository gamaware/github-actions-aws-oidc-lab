terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Same rule as infra/terraform: IAM and some services treat tag keys as
  # case-insensitive, so the default Purpose is dropped when var.tags sets it.
  default_tags {
    tags = merge(contains([for key in keys(var.tags) : lower(key)], "purpose") ? {} : { Purpose = "personal-lab" }, var.tags, {
      Project   = var.name
      ManagedBy = "terraform"
    })
  }
}
