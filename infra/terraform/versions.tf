terraform {
  # CI pins the exact version in .terraform-version. Validations that refer to
  # other variables need 1.9; 1.11 is the portfolio's common minimum.
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

  # IAM treats tag keys as case-insensitive, so the default Purpose is dropped
  # when var.tags sets purpose in any case; both would fail every IAM create.
  default_tags {
    tags = merge(contains([for key in keys(var.tags) : lower(key)], "purpose") ? {} : { Purpose = "personal-lab" }, var.tags, {
      Project   = var.name
      ManagedBy = "terraform"
    })
  }
}
