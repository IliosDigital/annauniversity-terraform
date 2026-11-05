resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Business metrics taken from the structured JSON log lines ------------------------------

locals {
  metric_namespace = "${var.project}/${var.environment}"

  functions = {
    api      = module.api.function_name
    ingest   = module.ingest.function_name
    generate = module.generate.function_name
  }

  log_metrics = {
    PapersCompleted  = { group = module.generate.log_group_name, pattern = "{ $.event = \"job_completed\" }" }
    PapersFailed     = { group = module.generate.log_group_name, pattern = "{ $.event = \"job_failed\" }" }
    TextbooksIndexed = { group = module.ingest.log_group_name, pattern = "{ $.event = \"ingest_completed\" }" }
    TextbooksFailed  = { group = module.ingest.log_group_name, pattern = "{ $.event = \"ingest_failed\" }" }
  }
}

resource "aws_cloudwatch_log_metric_filter" "this" {
  for_each = local.log_metrics

  name           = "${local.name}-${each.key}"
  log_group_name = each.value.group
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = local.metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

# --- Alarms -------------------------------------------------------------------------------------

locals {
  os_dimensions = { DomainName = local.opensearch_name, ClientId = local.account_id }

  alarms = merge(
    {
      for key, name in local.functions : "lambda-errors-${key}" => {
        description = "The ${key} Lambda function reported errors."
        namespace   = "AWS/Lambda"
        metric_name = "Errors"
        statistic   = "Sum"
        threshold   = 0
        operator    = "GreaterThanThreshold"
        dimensions  = { FunctionName = name }
      }
    },
    {
      for key in keys(local.queues) : "dead-letter-${key}" => {
        description = "Messages reached the ${key} dead-letter queue. Fix the cause, then redrive them."
        namespace   = "AWS/SQS"
        metric_name = "ApproximateNumberOfMessagesVisible"
        statistic   = "Maximum"
        threshold   = 0
        operator    = "GreaterThanThreshold"
        dimensions  = { QueueName = aws_sqs_queue.dlq[key].name }
      }
    },
    {
      queue-age-ingest = {
        description = "A textbook upload has waited over an hour to be processed."
        namespace   = "AWS/SQS"
        metric_name = "ApproximateAgeOfOldestMessage"
        statistic   = "Maximum"
        threshold   = 3600
        operator    = "GreaterThanThreshold"
        dimensions  = { QueueName = aws_sqs_queue.main["ingest"].name }
      }
      queue-age-generate = {
        description = "A question paper request has waited over 30 minutes."
        namespace   = "AWS/SQS"
        metric_name = "ApproximateAgeOfOldestMessage"
        statistic   = "Maximum"
        threshold   = 1800
        operator    = "GreaterThanThreshold"
        dimensions  = { QueueName = aws_sqs_queue.main["generate"].name }
      }
      api-5xx = {
        description = "The API returned 5xx responses."
        namespace   = "AWS/ApiGateway"
        metric_name = "5XXError"
        statistic   = "Sum"
        threshold   = 0
        operator    = "GreaterThanThreshold"
        dimensions = {
          ApiName = aws_api_gateway_rest_api.main.name
          Stage   = aws_api_gateway_stage.main.stage_name
        }
      }
      search-cluster-red = {
        description = "The OpenSearch cluster is red: some indexes are unavailable."
        namespace   = "AWS/ES"
        metric_name = "ClusterStatus.red"
        statistic   = "Maximum"
        threshold   = 0
        operator    = "GreaterThanThreshold"
        dimensions  = local.os_dimensions
      }
      search-free-storage = {
        description = "OpenSearch has less than 20% free storage on a node."
        namespace   = "AWS/ES"
        metric_name = "FreeStorageSpace"
        statistic   = "Minimum"
        threshold   = local.os_volume_gb * 1024 * 0.2 # the metric is in MB
        operator    = "LessThanThreshold"
        dimensions  = local.os_dimensions
      }
      search-cpu = {
        description = "OpenSearch CPU is above 80%."
        namespace   = "AWS/ES"
        metric_name = "CPUUtilization"
        statistic   = "Average"
        threshold   = 80
        operator    = "GreaterThanThreshold"
        dimensions  = local.os_dimensions
      }
    },
  )
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- Dashboard ------------------------------------------------------------------------------------

locals {
  api_dimensions = ["ApiName", aws_api_gateway_rest_api.main.name, "Stage", aws_api_gateway_stage.main.stage_name]

  dashboard_widgets = [
    {
      title = "API requests and errors"
      stat  = "Sum"
      metrics = [
        concat(["AWS/ApiGateway", "Count"], local.api_dimensions),
        concat(["AWS/ApiGateway", "4XXError"], local.api_dimensions),
        concat(["AWS/ApiGateway", "5XXError"], local.api_dimensions),
      ]
    },
    {
      title = "API latency (ms)"
      stat  = "p95"
      metrics = [
        concat(["AWS/ApiGateway", "Latency"], local.api_dimensions, [{ stat = "p50" }]),
        concat(["AWS/ApiGateway", "Latency"], local.api_dimensions, [{ stat = "p95" }]),
      ]
    },
    {
      title   = "Lambda errors"
      stat    = "Sum"
      metrics = [for key, name in local.functions : ["AWS/Lambda", "Errors", "FunctionName", name, { label = key }]]
    },
    {
      title   = "Lambda duration p95 (ms)"
      stat    = "p95"
      metrics = [for key, name in local.functions : ["AWS/Lambda", "Duration", "FunctionName", name, { label = key }]]
    },
    {
      title = "Queues: waiting and dead-lettered"
      stat  = "Maximum"
      metrics = concat(
        [for key in keys(local.queues) : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.main[key].name, { label = "${key} waiting" }]],
        [for key in keys(local.queues) : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq[key].name, { label = "${key} dead-letter" }]],
      )
    },
    {
      title = "Textbooks and question papers"
      stat  = "Sum"
      metrics = [
        [local.metric_namespace, "TextbooksIndexed"],
        [local.metric_namespace, "TextbooksFailed"],
        [local.metric_namespace, "PapersCompleted"],
        [local.metric_namespace, "PapersFailed"],
      ]
    },
    {
      title = "OpenSearch CPU and cluster status"
      stat  = "Maximum"
      metrics = [
        concat(["AWS/ES", "CPUUtilization"], flatten([for k, v in local.os_dimensions : [k, v]])),
        concat(["AWS/ES", "ClusterStatus.red"], flatten([for k, v in local.os_dimensions : [k, v]])),
        concat(["AWS/ES", "ClusterStatus.yellow"], flatten([for k, v in local.os_dimensions : [k, v]])),
      ]
    },
    {
      title = "OpenSearch free storage (MB)"
      stat  = "Minimum"
      metrics = [
        concat(["AWS/ES", "FreeStorageSpace"], flatten([for k, v in local.os_dimensions : [k, v]])),
      ]
    },
  ]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      for index, widget in local.dashboard_widgets : {
        type   = "metric"
        x      = (index % 2) * 12
        y      = floor(index / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = widget.title
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = widget.stat
          metrics = widget.metrics
        }
      }
    ]
  })
}

# --- Audit: CloudTrail for management events and access to textbooks and papers -------------------

locals {
  trail_name = local.name
  trail_arn  = "arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${local.name}"
}

resource "aws_s3_bucket" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket        = "${local.name}-trail-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    id     = "expire-audit-logs"
    status = "Enabled"
    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

data "aws_iam_policy_document" "trail_bucket" {
  count = local.enable_cloudtrail ? 1 : 0

  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "Write"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail[0].arn, "${aws_s3_bucket.trail[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count = local.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id
  policy = data.aws_iam_policy_document.trail_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "main" {
  count = local.enable_cloudtrail ? 1 : 0

  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "Access to textbooks and generated papers"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field = "resources.ARN"
      starts_with = [
        "${aws_s3_bucket.private["textbooks"].arn}/",
        "${aws_s3_bucket.private["outputs"].arn}/",
      ]
    }
  }

  depends_on = [aws_s3_bucket_policy.trail]
}
