output "repository_urls" {
  value = [for r in aws_ecr_repository.this : r.repository_url]
}

output "repository_arns" {
  value = [for r in aws_ecr_repository.this : r.arn]
}
