output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "lbc_role_arn" {
  description = "IAM role for the AWS Load Balancer Controller service account."
  value       = aws_iam_role.lbc.arn
}
