# Container registries for catalog services.
#   - Tag immutability and scan-on-push are hard-coded (not inputs).
#   - Lifecycle: untagged images expire after 1 day; the newest max_images are kept for rollback.
#   - Repository policy: ONLY the image-push role may push (even administrators cannot), so every
#     image in the registry went through the CI build, smoke test and Trivy gate.

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
  description = "KMS (AWS managed aws/ecr key, no extra cost) or AES256."
  type        = string
  default     = "KMS"
  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS."
  }
}

variable "push_role_arn" {
  description = "The only principal allowed to push images."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/", var.push_role_arn))
    error_message = "push_role_arn must be an IAM role ARN."
  }
}
