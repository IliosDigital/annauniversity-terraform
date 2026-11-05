locals {
  # Names derived from variables, so IAM can refer to them without creating cycles.
  models_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model"
}

# One package holds all three functions (src/api, src/ingest, src/generate and the
# shared src/common); each function selects its own handler.
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.root}/../src"
  output_path = "${path.root}/build/app.zip"
  excludes    = ["__pycache__", "*/__pycache__", "**/*.pyc"]
}

# --- Permissions ----------------------------------------------------------------------------

data "aws_iam_policy_document" "kms_use" {
  statement {
    sid = "UseDataKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.main.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "s3.${var.aws_region}.amazonaws.com",
        "dynamodb.${var.aws_region}.amazonaws.com",
      ]
    }
  }
}

# The generation model may be called only through its inference profile
# (pattern from the AWS documentation for global profiles).
data "aws_iam_policy_document" "bedrock_llm" {
  statement {
    sid       = "InvokeModelViaProfile"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.llm_profile_arn]
  }

  statement {
    sid     = "InvokeFoundationModelViaProfile"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "${local.models_arn}/${local.llm_foundation_model_id}",
      "arn:aws:bedrock:*::foundation-model/${local.llm_foundation_model_id}",
    ]

    condition {
      test     = "StringLike"
      variable = "bedrock:InferenceProfileArn"
      values   = [local.llm_profile_arn]
    }
  }
}

data "aws_iam_policy_document" "bedrock_embeddings" {
  statement {
    sid       = "InvokeEmbeddingModel"
    actions   = ["bedrock:InvokeModel"]
    resources = ["${local.models_arn}/${var.embedding_model_id}"]
  }
}

data "aws_iam_policy_document" "api" {
  source_policy_documents = [data.aws_iam_policy_document.kms_use.json]

  statement {
    sid       = "Registry"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.registry.arn, "${aws_dynamodb_table.registry.arn}/index/gsi1"]
  }

  # Presigned URLs carry the signer's permissions, so the role needs these.
  statement {
    sid       = "SignTextbookUploads"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.private["textbooks"].arn}/textbooks/*"]
  }

  statement {
    sid       = "SignPaperDownloads"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.private["outputs"].arn}/papers/*"]
  }

  statement {
    sid       = "QueueWork"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main["ingest"].arn, aws_sqs_queue.main["generate"].arn]
  }
}

data "aws_iam_policy_document" "ingest" {
  source_policy_documents = [
    data.aws_iam_policy_document.kms_use.json,
    data.aws_iam_policy_document.bedrock_embeddings.json,
  ]

  statement {
    sid       = "Registry"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.registry.arn]
  }

  statement {
    sid       = "ReadTextbooks"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.private["textbooks"].arn}/textbooks/*"]
  }

  statement {
    sid       = "ListTextbooks"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.private["textbooks"].arn]
  }

  statement {
    sid       = "WriteArtifacts"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.private["artifacts"].arn}/*"]
  }

  # Textract reads the textbook with the caller's own S3 permissions (above).
  statement {
    sid       = "Ocr"
    actions   = ["textract:StartDocumentTextDetection", "textract:GetDocumentTextDetection"]
    resources = ["*"]
  }

  statement {
    sid       = "ConsumeQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.main["ingest"].arn]
  }

  statement {
    sid       = "SearchIndex"
    actions   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpHead", "es:ESHttpDelete"]
    resources = ["${local.opensearch_arn}/*"]
  }
}

data "aws_iam_policy_document" "generate" {
  source_policy_documents = [
    data.aws_iam_policy_document.kms_use.json,
    data.aws_iam_policy_document.bedrock_llm.json,
    data.aws_iam_policy_document.bedrock_embeddings.json,
  ]

  statement {
    sid       = "Registry"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.registry.arn]
  }

  statement {
    sid       = "WritePapers"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.private["outputs"].arn}/papers/*"]
  }

  statement {
    sid       = "ConsumeQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.main["generate"].arn]
  }

  statement {
    sid       = "SearchIndex"
    actions   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpHead"]
    resources = ["${local.opensearch_arn}/*"]
  }
}

# --- Functions ---------------------------------------------------------------------------------

module "api" {
  source = "./modules/lambda_function"

  name         = "${local.name}-api"
  description  = "HTTP API: textbook registry, upload URLs and question-paper jobs"
  handler      = "api.handler.lambda_handler"
  package_path = data.archive_file.app.output_path
  package_hash = data.archive_file.app.output_base64sha256
  memory_mb    = 512
  timeout_s    = 20 # API Gateway gives up after 29 seconds

  environment = {
    ENVIRONMENT          = var.environment
    REGISTRY_TABLE       = aws_dynamodb_table.registry.name
    TEXTBOOK_BUCKET      = aws_s3_bucket.private["textbooks"].id
    OUTPUT_BUCKET        = aws_s3_bucket.private["outputs"].id
    INGEST_QUEUE_URL     = aws_sqs_queue.main["ingest"].id
    GENERATE_QUEUE_URL   = aws_sqs_queue.main["generate"].id
    MAX_UPLOAD_MB        = tostring(var.max_upload_mb)
    DOWNLOAD_URL_SECONDS = "900"
    JOB_RETENTION_DAYS   = tostring(var.job_retention_days)
    ALLOWED_ORIGIN       = local.web_origin
  }

  policy_json        = data.aws_iam_policy_document.api.json
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.lambda.id]
  log_retention_days = local.log_retention_days
}

module "ingest" {
  source = "./modules/lambda_function"

  name         = "${local.name}-ingest"
  description  = "Textbook ingestion: validate, extract, chunk, embed and index"
  handler      = "ingest.handler.lambda_handler"
  package_path = data.archive_file.app.output_path
  package_hash = data.archive_file.app.output_base64sha256
  memory_mb    = 1024
  timeout_s    = 900

  environment = {
    ENVIRONMENT         = var.environment
    REGISTRY_TABLE      = aws_dynamodb_table.registry.name
    TEXTBOOK_BUCKET     = aws_s3_bucket.private["textbooks"].id
    ARTIFACT_BUCKET     = aws_s3_bucket.private["artifacts"].id
    OPENSEARCH_ENDPOINT = aws_opensearch_domain.main.endpoint
    EMBEDDING_MODEL_ID  = var.embedding_model_id
    MAX_UPLOAD_MB       = tostring(var.max_upload_mb)
    MAX_RECEIVES        = tostring(local.max_receives)
  }

  policy_json        = data.aws_iam_policy_document.ingest.json
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.lambda.id]
  log_retention_days = local.log_retention_days
}

module "generate" {
  source = "./modules/lambda_function"

  name         = "${local.name}-generate"
  description  = "Question-paper generation: retrieve, write, check and deliver"
  handler      = "generate.handler.lambda_handler"
  package_path = data.archive_file.app.output_path
  package_hash = data.archive_file.app.output_base64sha256
  memory_mb    = 1024
  timeout_s    = 600

  environment = {
    ENVIRONMENT          = var.environment
    REGISTRY_TABLE       = aws_dynamodb_table.registry.name
    OUTPUT_BUCKET        = aws_s3_bucket.private["outputs"].id
    OPENSEARCH_ENDPOINT  = aws_opensearch_domain.main.endpoint
    EMBEDDING_MODEL_ID   = var.embedding_model_id
    LLM_MODEL_ID         = var.llm_model_id
    MAX_RECEIVES         = tostring(local.max_receives)
    SIMILARITY_THRESHOLD = tostring(var.duplicate_similarity)
  }

  policy_json        = data.aws_iam_policy_document.generate.json
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.lambda.id]
  log_retention_days = local.log_retention_days
}

# --- Triggers ------------------------------------------------------------------------------------

resource "aws_lambda_event_source_mapping" "ingest" {
  event_source_arn        = aws_sqs_queue.main["ingest"].arn
  function_name           = module.ingest.alias_arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.ingest_concurrency
  }
}

resource "aws_lambda_event_source_mapping" "generate" {
  event_source_arn        = aws_sqs_queue.main["generate"].arn
  function_name           = module.generate.alias_arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.generate_concurrency
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.api.function_name
  qualifier     = module.api.alias_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}
