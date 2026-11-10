resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.name}-api"
  description = "Question paper generation API (${var.environment})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# --- Resources ---------------------------------------------------------------------------------

locals {
  api_paths = {
    health           = "health"
    textbooks        = "textbooks"
    textbook         = "{textbook_id}"
    textbook_version = "{version}"
    reprocess        = "reprocess"
    papers           = "question-papers"
    paper            = "{job_id}"
  }
}

# One resource per path, created level by level so each parent exists first.
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = local.api_paths.health
}

resource "aws_api_gateway_resource" "textbooks" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = local.api_paths.textbooks
}

resource "aws_api_gateway_resource" "textbook" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.textbooks.id
  path_part   = local.api_paths.textbook
}

resource "aws_api_gateway_resource" "textbook_version" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.textbook.id
  path_part   = local.api_paths.textbook_version
}

resource "aws_api_gateway_resource" "reprocess" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.textbook_version.id
  path_part   = local.api_paths.reprocess
}

resource "aws_api_gateway_resource" "papers" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = local.api_paths.papers
}

resource "aws_api_gateway_resource" "paper" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.papers.id
  path_part   = local.api_paths.paper
}

# --- Authentication and request validation --------------------------------------------------

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${local.name}-cognito"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}

resource "aws_api_gateway_request_validator" "all" {
  name                        = "body-and-parameters"
  rest_api_id                 = aws_api_gateway_rest_api.main.id
  validate_request_body       = true
  validate_request_parameters = true
}

# The Lambda validates again; these models reject malformed bodies before it runs.
resource "aws_api_gateway_model" "create_textbook" {
  rest_api_id  = aws_api_gateway_rest_api.main.id
  name         = "CreateTextbook"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    type      = "object"
    required  = ["title", "subject", "version", "filename", "units"]
    properties = {
      title    = { type = "string", minLength = 1, maxLength = 200 }
      subject  = { type = "string", minLength = 1, maxLength = 100 }
      version  = { type = "string", minLength = 1, maxLength = 32 }
      filename = { type = "string", minLength = 1, maxLength = 100 }
      units    = { type = "array", minItems = 1, maxItems = 30 }
    }
  })
}

resource "aws_api_gateway_model" "create_paper" {
  rest_api_id  = aws_api_gateway_rest_api.main.id
  name         = "CreateQuestionPaper"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    type      = "object"
    required  = ["textbook_id", "version", "subject", "units", "difficulty", "count"]
    properties = {
      textbook_id = { type = "string", minLength = 1, maxLength = 32 }
      version     = { type = "string", minLength = 1, maxLength = 32 }
      subject     = { type = "string", minLength = 1, maxLength = 100 }
      units       = { type = "array", minItems = 1, maxItems = 30 }
      difficulty  = { type = "string", enum = ["Easy", "Medium", "Hard", "Mixed"] }
      count       = { type = "integer", minimum = 1, maximum = 100 }
    }
  })
}

# --- Routes ----------------------------------------------------------------------------------------

locals {
  # Everything except /health needs a signed-in user; the Lambda then checks the group.
  api_methods = {
    health             = { resource_id = aws_api_gateway_resource.health.id, http_method = "GET", public = true, model = null }
    list_textbooks     = { resource_id = aws_api_gateway_resource.textbooks.id, http_method = "GET", public = false, model = null }
    create_textbook    = { resource_id = aws_api_gateway_resource.textbooks.id, http_method = "POST", public = false, model = aws_api_gateway_model.create_textbook.name }
    get_textbook       = { resource_id = aws_api_gateway_resource.textbook_version.id, http_method = "GET", public = false, model = null }
    reprocess_textbook = { resource_id = aws_api_gateway_resource.reprocess.id, http_method = "POST", public = false, model = null }
    list_papers        = { resource_id = aws_api_gateway_resource.papers.id, http_method = "GET", public = false, model = null }
    create_paper       = { resource_id = aws_api_gateway_resource.papers.id, http_method = "POST", public = false, model = aws_api_gateway_model.create_paper.name }
    get_paper          = { resource_id = aws_api_gateway_resource.paper.id, http_method = "GET", public = false, model = null }
  }

  cors_resources = {
    health           = aws_api_gateway_resource.health.id
    textbooks        = aws_api_gateway_resource.textbooks.id
    textbook_version = aws_api_gateway_resource.textbook_version.id
    reprocess        = aws_api_gateway_resource.reprocess.id
    papers           = aws_api_gateway_resource.papers.id
    paper            = aws_api_gateway_resource.paper.id
  }
}

resource "aws_api_gateway_method" "this" {
  for_each = local.api_methods

  rest_api_id          = aws_api_gateway_rest_api.main.id
  resource_id          = each.value.resource_id
  http_method          = each.value.http_method
  authorization        = each.value.public ? "NONE" : "COGNITO_USER_POOLS"
  authorizer_id        = each.value.public ? null : aws_api_gateway_authorizer.cognito.id
  request_validator_id = aws_api_gateway_request_validator.all.id
  request_models       = each.value.model == null ? null : { "application/json" = each.value.model }
}

resource "aws_api_gateway_integration" "this" {
  for_each = local.api_methods

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = each.value.resource_id
  http_method             = aws_api_gateway_method.this[each.key].http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = module.api.alias_invoke_arn
  timeout_milliseconds    = 29000
}

# --- CORS: the web application on CloudFront calls this API from the browser -------------------

resource "aws_api_gateway_method" "options" {
  for_each = local.cors_resources

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = each.value
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options" {
  for_each = local.cors_resources

  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = each.value
  http_method = aws_api_gateway_method.options[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "options" {
  for_each = local.cors_resources

  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = each.value
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "options" {
  for_each = local.cors_resources

  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = each.value
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = aws_api_gateway_method_response.options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'${local.web_origin}'"
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type,Idempotency-Key,X-Correlation-Id'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
  }

  depends_on = [aws_api_gateway_integration.options]
}

# Errors produced by API Gateway itself (validation, authorizer) also need the header.
resource "aws_api_gateway_gateway_response" "cors" {
  for_each = toset(["DEFAULT_4XX", "DEFAULT_5XX"])

  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = each.key

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin" = "'${local.web_origin}'"
  }
}

# --- Stage ---------------------------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # A new deployment is created whenever a route, model, authorizer or integration changes.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_authorizer.cognito.id,
      aws_api_gateway_model.create_textbook.schema,
      aws_api_gateway_model.create_paper.schema,
      aws_api_gateway_method.this,
      aws_api_gateway_integration.this,
      aws_api_gateway_method.options,
      aws_api_gateway_integration_response.options,
      aws_api_gateway_gateway_response.cors,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id          = aws_api_gateway_rest_api.main.id
  deployment_id        = aws_api_gateway_deployment.main.id
  stage_name           = var.environment
  xray_tracing_enabled = true
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    throttling_rate_limit  = local.is_prod ? 50 : 10
    throttling_burst_limit = local.is_prod ? 100 : 20
  }
}

# --- WAF (on by default in prod) -------------------------------------------------------------------

resource "aws_wafv2_web_acl" "api" {
  count = local.enable_waf ? 1 : 0

  name  = "${local.name}-api"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 300 # requests per 5 minutes per IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common-rules"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-api"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "api" {
  count = local.enable_waf ? 1 : 0

  resource_arn = aws_api_gateway_stage.main.arn
  web_acl_arn  = aws_wafv2_web_acl.api[0].arn
}
