provider "aws" {
  region = var.region

  # Guard 1 of 2: the provider refuses to run against any other account, before any API call that
  # changes anything. Guard 2 is the postcondition on data.aws_caller_identity in main.tf.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}
