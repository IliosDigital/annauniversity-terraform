# One-time setup, run by an administrator from a workstation:
#   terraform init && terraform apply
# It creates what the pipeline needs before it can run: the Terraform state bucket
# and the IAM roles GitHub Actions assumes through OpenID Connect (no long-lived
# AWS keys are ever stored in GitHub). Keep this stack's own state safe; it
# changes rarely.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Owner     = var.owner
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo       = var.github_repository
  oidc_arn   = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# --- Terraform state ----------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${local.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled" # every earlier state can be restored
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- GitHub OIDC trust -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_service_linked_role" "opensearch" {
  count = var.create_opensearch_service_linked_role ? 1 : 0

  aws_service_name = "opensearchservice.amazonaws.com"
}

# Only workflows of this repository, and only the listed subjects, can assume a role.
data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/main"]
    }
  }

  depends_on = [aws_iam_openid_connect_provider.github]
}

data "aws_iam_policy_document" "trust_apply" {
  for_each = toset(var.environments)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Deployments run in a GitHub environment, which is where required reviewers
    # (the release approval) are enforced.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:environment:${each.key}"]
    }
  }

  depends_on = [aws_iam_openid_connect_provider.github]
}

# --- Plan role: read-only, used by pull requests --------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  # Planning reads the state and takes the lock (a .tflock object). It cannot
  # write the state itself.
  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/infra/*"]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/infra/*.tflock"]
  }

  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # ReadOnlyAccess reaches into data. A pull request must see infrastructure, not
  # textbooks, examination papers, records or secrets. The state objects above are the
  # only exception: an explicit Deny beats an Allow, so they are excluded here.
  statement {
    sid    = "NoDataAccess"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "secretsmanager:GetSecretValue",
      "kms:Decrypt",
      "sqs:ReceiveMessage",
    ]
    not_resources = ["${aws_s3_bucket.state.arn}/infra/*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# --- Apply roles: one per environment, assumable only from its GitHub environment -----------------

resource "aws_iam_role" "apply" {
  for_each = toset(var.environments)

  name                 = "${var.project}-github-apply-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  for_each = toset(var.environments)

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/infra/${each.key}/*"]
  }

  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # Resources named <project>-<environment>-* can be fully managed...
  statement {
    sid     = "ManageNamedResources"
    actions = ["s3:*", "dynamodb:*", "sqs:*", "sns:*", "lambda:*", "events:*"]
    resources = [
      "arn:aws:s3:::${var.project}-${each.key}-*",
      "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.project}-${each.key}-*",
      "arn:aws:sqs:${var.aws_region}:${local.account_id}:${var.project}-${each.key}-*",
      "arn:aws:sns:${var.aws_region}:${local.account_id}:${var.project}-${each.key}-*",
      "arn:aws:lambda:${var.aws_region}:${local.account_id}:function:${var.project}-${each.key}-*",
      "arn:aws:events:${var.aws_region}:${local.account_id}:rule/${var.project}-${each.key}-*",
    ]
  }

  statement {
    sid       = "ManageObjectsInNamedBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${var.project}-${each.key}-*/*"]
  }

  # ...services whose actions cannot be limited by resource name are allowed
  # service-wide, in the deploy account only.
  statement {
    sid = "ManageServices"
    actions = [
      "ec2:*",
      "apigateway:*",
      "es:*",
      "cognito-idp:*",
      "cloudfront:*",
      "wafv2:*",
      "cloudwatch:*",
      "logs:*",
      "cloudtrail:*",
      "xray:*",
      "kms:*",
      "tag:GetResources",
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:ListEventSourceMappings",
    ]
    resources = ["*"]
  }

  # IAM is the sharpest tool: the pipeline may manage only this environment's roles.
  statement {
    sid = "ManageEnvironmentRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  for_each = toset(var.environments)

  name   = "deploy"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply[each.key].json
}
