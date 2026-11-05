variable "name" {
  description = "Function name, also used for the IAM role and log group."
  type        = string
}

variable "description" {
  description = "What the function does."
  type        = string
}

variable "handler" {
  description = "Python handler, for example api.handler.lambda_handler."
  type        = string
}

variable "package_path" {
  description = "Path of the deployment zip."
  type        = string
}

variable "package_hash" {
  description = "Base64 SHA-256 of the deployment zip, so code changes publish a new version."
  type        = string
}

variable "memory_mb" {
  description = "Memory in MB."
  type        = number
}

variable "timeout_s" {
  description = "Timeout in seconds."
  type        = number
}

variable "environment" {
  description = "Environment variables."
  type        = map(string)
}

variable "policy_json" {
  description = "IAM policy document (JSON) with the function's own permissions."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets the function runs in."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups of the function."
  type        = list(string)
}

variable "log_retention_days" {
  description = "Retention of the function's log group in days."
  type        = number
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions, or null for none."
  type        = number
  default     = null
}
