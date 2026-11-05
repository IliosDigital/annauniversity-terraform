output "function_name" {
  description = "Function name."
  value       = aws_lambda_function.this.function_name
}

output "alias_name" {
  description = "Alias callers should use."
  value       = aws_lambda_alias.live.name
}

output "alias_arn" {
  description = "ARN of the live alias (use for event source mappings)."
  value       = aws_lambda_alias.live.arn
}

output "alias_invoke_arn" {
  description = "Invoke ARN of the live alias (use for API Gateway)."
  value       = aws_lambda_alias.live.invoke_arn
}

output "role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}
