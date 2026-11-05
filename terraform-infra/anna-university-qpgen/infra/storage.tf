locals {
  private_buckets = toset(["textbooks", "artifacts", "outputs"])
  bucket_names    = { for k in local.private_buckets : k => "${local.name}-${k}-${local.account_id}" }
  web_origin      = "https://${aws_cloudfront_distribution.web.domain_name}"
}

# --- Private buckets: raw textbooks, processed artifacts, generated papers ---------------

resource "aws_s3_bucket" "private" {
  for_each = local.private_buckets

  bucket        = local.bucket_names[each.key]
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "private" {
  for_each = local.private_buckets

  bucket                  = aws_s3_bucket.private[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  for_each = local.private_buckets

  bucket = aws_s3_bucket.private[each.key].id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

# Object versions drive ingestion idempotency, so the textbook bucket is versioned.
resource "aws_s3_bucket_versioning" "textbooks" {
  bucket = aws_s3_bucket.private["textbooks"].id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "private_bucket" {
  for_each = local.private_buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.private[each.key].arn, "${aws_s3_bucket.private[each.key].arn}/*"]

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

resource "aws_s3_bucket_policy" "private" {
  for_each = local.private_buckets

  bucket = aws_s3_bucket.private[each.key].id
  policy = data.aws_iam_policy_document.private_bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.private]
}

# S3 sends every object-created event to EventBridge, which routes uploads to the
# ingestion queue (messaging.tf).
resource "aws_s3_bucket_notification" "textbooks" {
  bucket      = aws_s3_bucket.private["textbooks"].id
  eventbridge = true
}

# Browsers upload with a presigned POST, so the web origin must be allowed.
resource "aws_s3_bucket_cors_configuration" "textbooks" {
  bucket = aws_s3_bucket.private["textbooks"].id

  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = [local.web_origin]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "textbooks" {
  bucket = aws_s3_bucket.private["textbooks"].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.textbooks]
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.private["artifacts"].id

  rule {
    id     = "expire-intermediate-outputs"
    status = "Enabled"

    filter {
      prefix = "intermediate/"
    }

    expiration {
      days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "outputs" {
  bucket = aws_s3_bucket.private["outputs"].id

  rule {
    id     = "expire-generated-papers"
    status = "Enabled"

    filter {
      prefix = "papers/"
    }

    expiration {
      days = var.output_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- Web application: static UI on S3 behind CloudFront ------------------------------------

resource "aws_s3_bucket" "web" {
  bucket        = "${local.name}-web-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # static, public-facing files; CloudFront cannot use a KMS key here
    }
  }
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    sid       = "AllowCloudFrontOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.web.arn, "${aws_s3_bucket.web.arn}/*"]

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

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.web]
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${local.name}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name} web application"
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes India

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id           = "web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # Single-page app: unknown paths fall back to the app shell.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Runtime settings the static UI loads, so the same build works in every environment.
resource "aws_s3_object" "web_config" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.json"
  content_type = "application/json"

  content = jsonencode({
    apiUrl         = aws_api_gateway_stage.main.invoke_url
    region         = var.aws_region
    userPoolId     = aws_cognito_user_pool.main.id
    userPoolClient = aws_cognito_user_pool_client.web.id
    cognitoDomain  = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
  })
}
