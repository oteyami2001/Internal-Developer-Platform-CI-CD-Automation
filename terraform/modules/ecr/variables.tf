# tflint-ignore-file: terraform_unused_declarations # SKELETON: inputs are the contract; resources arrive in Phase 3/4.
# Remove this line when the configuration gets resources (enforced by tests/platform/test_repo_hygiene.py).

# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 3, bootstrap)
#
# Planned resources per repository:
#   aws_ecr_repository (image_tag_mutability = IMMUTABLE - hard-coded, scan_on_push = true)
#   aws_ecr_lifecycle_policy (keep the newest max_images; expire untagged after 1 day)
#   aws_ecr_repository_policy (pull: ECS execution roles of this account; push: image-push role only)

variable "repositories" {
  description = "Repository name -> settings. One repository per catalog service."
  type = map(object({
    max_images = optional(number, 20)
  }))
  validation {
    condition     = alltrue([for name in keys(var.repositories) : can(regex("^[a-z][a-z0-9-]{1,40}/[a-z][a-z0-9-]{1,30}$", name))])
    error_message = "Repository names must be '<project>/<service>' in lowercase."
  }
  validation {
    condition     = alltrue([for r in values(var.repositories) : r.max_images >= 3 && r.max_images <= 100])
    error_message = "max_images must be 3-100 (keep enough images to roll back)."
  }
}

variable "encryption_type" {
  type    = string
  default = "AES256"
  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS."
  }
}

variable "push_role_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
