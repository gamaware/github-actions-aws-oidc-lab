output "deploy_role_arn" {
  description = "Put this in the GitLab CI/CD variable AWS_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "trusted_subjects" {
  description = "The only GitLab ID token subjects the role accepts."
  value       = local.trusted_subjects
}
