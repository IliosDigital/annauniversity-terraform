variable "aws_region" {
  description = "AWS region for the state bucket and the stack."
  type        = string
  default     = "ap-south-2"
}

variable "project" {
  description = "Short project name. Must match the project variable of infra/, because the deploy roles are scoped to resources that start with it."
  type        = string
  default     = "qpgen"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.project))
    error_message = "project must be 2-12 lowercase letters, digits or hyphens and start with a letter."
  }
}

variable "github_repository" {
  description = "The private GitHub repository that deploys the stack, as owner/name. This is an assumed name: replace it with the real repository before applying, because the deploy roles trust only this repository."
  type        = string
  default     = "fiducia-ventures/anna-university-question-paper-generation"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "environments" {
  description = "Deployment environments. Each needs a GitHub environment of the same name; protect prod with required reviewers."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set false if the account already has one (it can exist only once per account)."
  type        = bool
  default     = true
}

variable "create_opensearch_service_linked_role" {
  description = "Create the OpenSearch service-linked role. Set true only if the account has never had a VPC OpenSearch domain."
  type        = bool
  default     = false
}

variable "owner" {
  description = "Owning team, added to every resource as a tag."
  type        = string
  default     = "Fiducia Ventures"
}
