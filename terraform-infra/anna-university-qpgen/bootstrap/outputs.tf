output "state_bucket" {
  description = "Terraform state bucket. Set it as the GitHub repository variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  description = "Set as the GitHub repository variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arns" {
  description = "Set each as the variable AWS_APPLY_ROLE_ARN in the GitHub environment of the same name."
  value       = { for env, role in aws_iam_role.apply : env => role.arn }
}

output "github_setup" {
  description = "What to configure in GitHub after this apply."
  value       = <<-EOT
    Repository ${var.github_repository} -> Settings -> Secrets and variables -> Actions -> Variables:
      AWS_REGION        = ${var.aws_region}
      TF_STATE_BUCKET   = ${aws_s3_bucket.state.id}
      AWS_PLAN_ROLE_ARN = ${aws_iam_role.plan.arn}
      ALERT_EMAIL       = (address that receives alarm notifications)
    Settings -> Environments: create ${join(", ", var.environments)}; in each, add the variable
    AWS_APPLY_ROLE_ARN (see apply_role_arns). Add required reviewers to prod.
  EOT
}
