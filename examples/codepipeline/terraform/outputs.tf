output "pipeline_name" {
  description = "Name of the pipeline, for aws codepipeline start-pipeline-execution."
  value       = aws_codepipeline.this.name
}

output "artifact_bucket" {
  description = "Artifact bucket. With source_type = s3, upload the source zip to source_object_key here."
  value       = aws_s3_bucket.artifacts.bucket
}

output "connection_arn" {
  description = "CodeConnections connection to complete once in the console. Null when source_type is s3."
  value       = one(aws_codeconnections_connection.github[*].arn)
}

output "stage_names" {
  description = "Pipeline stages in order."
  value       = [for stage in aws_codepipeline.this.stage : stage.name]
}

output "pipeline_role_arn" {
  description = "Role CodePipeline assumes; it also runs the ECS deploy action."
  value       = aws_iam_role.pipeline.arn
}

output "build_role_arn" {
  description = "Role of the build project, the only one that can push to the ECR repository."
  value       = aws_iam_role.build.arn
}

output "verify_role_arn" {
  description = "Role of the verify project, read-only on the ECS service."
  value       = aws_iam_role.verify.arn
}
