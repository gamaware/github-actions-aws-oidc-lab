output "deploy_role_arn" {
  description = "Put this in the repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "ecr_repository_url" {
  description = "Put this in the repository variable ECR_REPOSITORY_URL."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  description = "Put this in the repository variable ECS_CLUSTER."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service" {
  description = "Put this in the repository variable ECS_SERVICE."
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Put this in the repository variable ECS_TASK_FAMILY."
  value       = aws_ecs_task_definition.app.family
}

output "trusted_subjects" {
  description = "The only OIDC subjects the deploy role accepts."
  value       = local.trusted_subjects
}

output "plan_role_arn" {
  description = "Put this in the repository variable AWS_PLAN_ROLE_ARN. Null unless create_plan_role is true."
  value       = one(aws_iam_role.plan[*].arn)
}
