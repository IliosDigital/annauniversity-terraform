# Two pipelines, each a queue with a dead-letter queue:
#   textbook upload  -> EventBridge -> ingest queue   -> ingest Lambda
#   paper request    -> API Lambda  -> generate queue -> generate Lambda

locals {
  max_receives = 3 # tries before a message goes to the dead-letter queue

  # visibility timeout = 6x the function timeout (AWS guidance for Lambda consumers)
  queues = {
    ingest   = { visibility = 6 * 900 }
    generate = { visibility = 6 * 600 }
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate and replay
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  for_each = local.queues

  name                       = "${local.name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = local.max_receives
  })
}

# Let the DLQ be replayed into its source queue from the console or CLI.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.queues

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

# --- Textbook upload events -------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "textbook_uploaded" {
  name        = "${local.name}-textbook-uploaded"
  description = "New object in the textbook bucket"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.private["textbooks"].id] }
      object = { key = [{ prefix = "textbooks/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "ingest_queue" {
  rule = aws_cloudwatch_event_rule.textbook_uploaded.name
  arn  = aws_sqs_queue.main["ingest"].arn

  retry_policy {
    maximum_retry_attempts       = 10
    maximum_event_age_in_seconds = 3600
  }
}

data "aws_iam_policy_document" "ingest_queue" {
  statement {
    sid       = "AllowEventBridge"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main["ingest"].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.textbook_uploaded.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.main["ingest"].arn]

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

resource "aws_sqs_queue_policy" "ingest" {
  queue_url = aws_sqs_queue.main["ingest"].id
  policy    = data.aws_iam_policy_document.ingest_queue.json
}
