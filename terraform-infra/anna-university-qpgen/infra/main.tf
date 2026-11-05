data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id

  # Differences between prod and the other environments live here, nowhere else.
  is_prod            = var.environment == "prod"
  az_count           = local.is_prod ? 2 : 1
  azs                = slice(coalesce(var.availability_zones, ["${var.aws_region}a", "${var.aws_region}b"]), 0, local.az_count)
  enable_waf         = coalesce(var.enable_waf, local.is_prod)
  enable_cloudtrail  = coalesce(var.enable_cloudtrail, local.is_prod)
  log_retention_days = coalesce(var.log_retention_days, local.is_prod ? 90 : 14)

  os_instance_type  = coalesce(var.opensearch_instance_type, local.is_prod ? "m7g.large.search" : "t3.small.search")
  os_instance_count = coalesce(var.opensearch_instance_count, local.az_count)
  os_volume_gb      = coalesce(var.opensearch_volume_gb, local.is_prod ? 100 : 20)

  # global.anthropic.claude-sonnet-5-5 -> anthropic.claude-sonnet-5-5
  llm_foundation_model_id = regex("^[a-z]+\\.(anthropic\\..+)$", var.llm_model_id)[0]
  llm_profile_arn         = "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${var.llm_model_id}"

  tags = merge(var.tags, {
    Project            = var.project
    Environment        = var.environment
    Owner              = var.owner
    CostCenter         = var.cost_center
    DataClassification = var.data_classification
    ManagedBy          = "terraform"
  })
}

# Non-blocking reminders: Terraform prints a warning, the plan still succeeds.
check "alert_email_set_in_prod" {
  assert {
    condition     = !local.is_prod || var.alert_email != ""
    error_message = "alert_email is empty, so production alarms will fire without anyone being notified. Set alert_email."
  }
}

check "opensearch_zones_match_nodes" {
  assert {
    condition     = local.os_instance_count % local.az_count == 0
    error_message = "opensearch_instance_count must be a multiple of the availability zone count (${local.az_count})."
  }
}

# --- Encryption ------------------------------------------------------------------------

resource "aws_kms_key" "main" {
  description             = "${local.name} data encryption (textbooks, papers, registry, search index)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}
