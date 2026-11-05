# --- Job and textbook registry (single table, see src/common/registry.py) -----------------

resource "aws_dynamodb_table" "registry" {
  name         = "${local.name}-registry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "gsi1pk"
    type = "S"
  }

  attribute {
    name = "gsi1sk"
    type = "S"
  }

  # Lists textbooks and a user's jobs.
  global_secondary_index {
    name            = "gsi1"
    projection_type = "ALL"

    key_schema {
      attribute_name = "gsi1pk"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "gsi1sk"
      key_type       = "RANGE"
    }
  }

  # Idempotency records and old jobs expire on their own.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = local.is_prod
}

# --- OpenSearch: textbook passages (BM25 + vectors) and the question bank ------------------

locals {
  opensearch_name = "${local.name}-search" # domain names are limited to 28 characters
  opensearch_arn  = "arn:aws:es:${var.aws_region}:${local.account_id}:domain/${local.opensearch_name}"
}

resource "aws_iam_service_linked_role" "opensearch" {
  count = var.create_opensearch_service_linked_role ? 1 : 0

  aws_service_name = "opensearchservice.amazonaws.com"
}

resource "aws_cloudwatch_log_group" "opensearch" {
  for_each = toset(["application", "search-slow", "index-slow"])

  name              = "/aws/opensearch/${local.opensearch_name}/${each.key}"
  retention_in_days = local.log_retention_days
}

data "aws_iam_policy_document" "opensearch_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for g in aws_cloudwatch_log_group.opensearch : "${g.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["es.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  policy_name     = "${local.opensearch_name}-logs"
  policy_document = data.aws_iam_policy_document.opensearch_logs.json
}

# Access is limited to the VPC (security group) and to the three Lambda roles that
# need the index; nothing is public.
data "aws_iam_policy_document" "opensearch_access" {
  statement {
    actions   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpHead", "es:ESHttpDelete"]
    resources = ["${local.opensearch_arn}/*"]

    principals {
      type = "AWS"
      identifiers = [
        module.ingest.role_arn,
        module.generate.role_arn,
      ]
    }
  }
}

resource "aws_opensearch_domain" "main" {
  domain_name     = local.opensearch_name
  engine_version  = var.opensearch_version
  access_policies = data.aws_iam_policy_document.opensearch_access.json

  cluster_config {
    instance_type          = local.os_instance_type
    instance_count         = local.os_instance_count
    zone_awareness_enabled = local.az_count > 1

    dynamic "zone_awareness_config" {
      for_each = local.az_count > 1 ? [1] : []

      content {
        availability_zone_count = local.az_count
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = local.os_volume_gb
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.main.arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-PFS-2023-10"
  }

  vpc_options {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.opensearch.id]
  }

  log_publishing_options {
    log_type                 = "ES_APPLICATION_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch["application"].arn
  }

  log_publishing_options {
    log_type                 = "SEARCH_SLOW_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch["search-slow"].arn
  }

  log_publishing_options {
    log_type                 = "INDEX_SLOW_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch["index-slow"].arn
  }

  depends_on = [
    aws_cloudwatch_log_resource_policy.opensearch,
    aws_iam_service_linked_role.opensearch,
  ]
}
