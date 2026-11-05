output "web_url" {
  description = "Address of the web application (CloudFront)."
  value       = local.web_origin
}

output "web_bucket" {
  description = "Bucket the static web application is synced to."
  value       = aws_s3_bucket.web.id
}

output "api_url" {
  description = "Base URL of the API."
  value       = aws_api_gateway_stage.main.invoke_url
}

output "user_pool_id" {
  description = "Cognito user pool. Create users here and add them to the faculty or administrator group."
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  description = "Cognito app client used by the web application."
  value       = aws_cognito_user_pool_client.web.id
}

output "buckets" {
  description = "Data buckets."
  value       = { for k, b in aws_s3_bucket.private : k => b.id }
}

output "queues" {
  description = "Work queues and their dead-letter queues."
  value = {
    for k in keys(local.queues) : k => {
      url      = aws_sqs_queue.main[k].id
      dlq_url  = aws_sqs_queue.dlq[k].id
      dlq_name = aws_sqs_queue.dlq[k].name
    }
  }
}

output "registry_table" {
  description = "DynamoDB job and textbook registry."
  value       = aws_dynamodb_table.registry.name
}

output "opensearch_endpoint" {
  description = "OpenSearch endpoint (reachable only from inside the VPC)."
  value       = aws_opensearch_domain.main.endpoint
}

output "kms_key_arn" {
  description = "Customer-managed key for buckets, registry and search index."
  value       = aws_kms_key.main.arn
}

output "lambda_functions" {
  description = "Function names. Callers use the live alias; point it at an earlier version to roll back."
  value       = local.functions
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic that receives alarm notifications."
  value       = aws_sns_topic.alerts.arn
}
