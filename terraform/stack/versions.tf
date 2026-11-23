terraform {
  # >= 1.10 for native S3 state locking (use_lockfile) and cross-variable validation (>= 1.9).
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73" # exact build pinned by .terraform.lock.hcl
    }
  }

  # Partial configuration: bucket/key/region come from terraform/envs/<env>/backend.hcl so every
  # environment has its own state object (and lock file) in the encrypted, versioned state bucket.
  backend "s3" {}
}
