terraform {
  # 1.10 added native S3 state locking (use_lockfile), so no lock table is needed.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # State lives in the S3 bucket that bootstrap/ creates. Bucket and key are
  # passed at init time (see .github/workflows/terraform.yml) so one code base
  # serves every environment with its own state file.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}
