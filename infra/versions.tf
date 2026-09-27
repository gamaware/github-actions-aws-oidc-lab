terraform {
  # CI pins the exact version in .terraform-version; 1.9 is the minimum for
  # validations that refer to other variables.
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
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
      Purpose   = "personal-lab"
    }
  }
}
