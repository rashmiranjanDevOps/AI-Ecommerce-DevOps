output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecr_repository_url" {
  description = "Push images here (the Jenkins pipeline does this)."
  value       = module.ecr.repository_urls[0]
}

output "ecr_registry" {
  description = "Value for the Jenkins global variable ECR_REGISTRY."
  value       = split("/", module.ecr.repository_urls[0])[0]
}

output "eks_cluster_name" {
  description = "Value for the Jenkins global variable EKS_CLUSTER_NAME."
  value       = module.eks.cluster_name
}

output "lbc_role_arn" {
  description = "Used by scripts/deploy.sh addons to install the AWS Load Balancer Controller."
  value       = module.eks.lbc_role_arn
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "jenkins_url" {
  value = var.enable_jenkins ? "http://${module.jenkins[0].public_ip}:8080" : null
}

output "jenkins_public_ip" {
  value = var.enable_jenkins ? module.jenkins[0].public_ip : null
}

output "app_server_public_ip" {
  value = var.enable_app_server ? module.app_server[0].public_ip : null
}

output "ansible_inventory_file" {
  value = "ansible/inventory.${var.environment}.ini"
}

output "next_steps" {
  value = <<-EOT
    1. aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}
    2. kubectl apply -f kubernetes/namespace.yaml -f kubernetes/rbac.yaml
    3. ./scripts/deploy.sh addons        (AWS Load Balancer Controller, metrics-server, Prometheus/Grafana)
    4. cd ansible && ansible-playbook -i inventory.${var.environment}.ini playbook.yml
    5. In Jenkins the variables ECR_REGISTRY, EKS_CLUSTER_NAME, AWS_REGION are set by Ansible
  EOT
}
