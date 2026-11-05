variable "aws_region" {
  description = "AWS region of the stack. Bedrock, Textract and OpenSearch were confirmed available in ap-south-1."
  type        = string
  default     = "ap-south-2"
}

variable "project" {
  description = "Short project name used as a prefix for every resource."
  type        = string
  default     = "qpgen"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.project))
    error_message = "project must be 2-12 lowercase letters, digits or hyphens and start with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. prod turns on the production controls: two availability zones, WAF, CloudTrail, deletion protection, MFA and longer retention."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

# --- Models (read from AWS, not assumed) -------------------------------------------

variable "llm_model_id" {
  description = "Bedrock inference profile id of the Claude model that writes the questions. Read from `aws bedrock list-inference-profiles --region ap-south-1`. global. profiles may process requests in other regions; use an in. profile to keep traffic in India."
  type        = string
  default     = "global.anthropic.claude-sonnet-5-5"

  validation {
    condition     = can(regex("^[a-z]+\\.anthropic\\.[a-z0-9.:-]+$", var.llm_model_id))
    error_message = "llm_model_id must be an inference profile id such as global.anthropic.claude-sonnet-5-5."
  }
}

variable "embedding_model_id" {
  description = "Bedrock embedding model. Titan Text Embeddings V2 is callable on demand in ap-south-1 and the code requests 1024 dimensions."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "duplicate_similarity" {
  description = "Cosine similarity at or above which two questions count as the same. 0.80 sits between measured re-asked questions (0.86-0.89) and different questions (0.65 or less); lower it to be stricter."
  type        = number
  default     = 0.80

  validation {
    condition     = var.duplicate_similarity > 0.5 && var.duplicate_similarity < 1
    error_message = "duplicate_similarity must be between 0.5 and 1."
  }
}

# --- Network -------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block of the private VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to use. Null means <region>a and <region>b."
  type        = list(string)
  default     = null
}

# --- OpenSearch ----------------------------------------------------------------------

variable "opensearch_version" {
  description = "OpenSearch engine version, taken from `aws opensearch list-versions --region ap-south-1`."
  type        = string
  default     = "OpenSearch_3.7"
}

variable "opensearch_instance_type" {
  description = "Data node type. Null means m7g.large.search in prod and t3.small.search elsewhere (both listed as available in ap-south-1)."
  type        = string
  default     = null
}

variable "opensearch_instance_count" {
  description = "Number of data nodes. Null means 2 in prod (one per availability zone) and 1 elsewhere."
  type        = number
  default     = null
}

variable "opensearch_volume_gb" {
  description = "EBS volume per data node in GB. Null means 100 in prod and 20 elsewhere."
  type        = number
  default     = null
}

variable "create_opensearch_service_linked_role" {
  description = "Create the OpenSearch service-linked role. Set true only if this account has never had a VPC OpenSearch domain; creating it twice fails."
  type        = bool
  default     = false
}

# --- Behaviour -----------------------------------------------------------------------

variable "max_upload_mb" {
  description = "Largest textbook file accepted, in MB."
  type        = number
  default     = 100
}

variable "ingest_concurrency" {
  description = "Textbooks processed in parallel. Keep modest: they share OpenSearch and the Bedrock embedding quota."
  type        = number
  default     = 2
}

variable "generate_concurrency" {
  description = "Question papers generated in parallel. Bounded by the Bedrock model quota."
  type        = number
  default     = 5
}

variable "job_retention_days" {
  description = "Days a generation job record is kept before DynamoDB deletes it."
  type        = number
  default     = 90
}

variable "output_retention_days" {
  description = "Days generated papers are kept in S3."
  type        = number
  default     = 90
}

variable "log_retention_days" {
  description = "Retention of Lambda log groups in days. Null means 90 in prod and 14 elsewhere."
  type        = number
  default     = null
}

variable "enable_waf" {
  description = "Attach a WAF web ACL to the API. Null means on in prod, off elsewhere."
  type        = bool
  default     = null
}

variable "enable_cloudtrail" {
  description = "Create a trail for management events and object access to textbooks and papers. Null means on in prod. Leave off if an organisation trail already covers the account."
  type        = bool
  default     = null
}

variable "alert_email" {
  description = "Email address subscribed to alarm notifications. Empty means no subscription is created."
  type        = string
  default     = ""
}

variable "owner" {
  description = "Owning team, added to every resource as a tag."
  type        = string
  default     = "Fiducia Ventures"
}

variable "cost_center" {
  description = "Cost allocation tag."
  type        = string
  default     = "ai-practice"
}

variable "data_classification" {
  description = "Data classification tag. Textbooks and examination papers are confidential."
  type        = string
  default     = "confidential"
}

variable "tags" {
  description = "Extra tags added to every resource."
  type        = map(string)
  default     = {}
}
