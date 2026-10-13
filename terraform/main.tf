locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = local.name
  tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "davine-internship"
  }, var.extra_tags)
}

module "network" {
  source = "./modules/network"

  name               = local.name
  cluster_name       = local.cluster_name
  cidr               = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "ecr" {
  source = "./modules/ecr"

  repositories = ["${var.project}-web"]
  keep_images  = var.ecr_keep_images
  force_delete = var.ecr_force_delete
}

module "eks" {
  source = "./modules/eks"

  name                = local.cluster_name
  cluster_version     = var.cluster_version
  subnet_ids          = module.network.private_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

module "jenkins" {
  count  = var.enable_jenkins ? 1 : 0
  source = "./modules/compute"

  name                 = "${local.name}-jenkins"
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.public_subnet_ids[0]
  instance_type        = var.jenkins_instance_type
  key_name             = var.ssh_key_name
  volume_size          = 50
  allocate_eip         = true
  ecr_repository_arns  = module.ecr.repository_arns
  ecr_push             = true
  allow_eks_describe   = true
  ingress_rules = [
    { description = "SSH from admin", port = 22, cidrs = var.admin_cidrs },
    { description = "Jenkins UI from admin and webhook IPs", port = 8080, cidrs = concat(var.admin_cidrs, var.webhook_cidrs) },
  ]
}

module "app_server" {
  count  = var.enable_app_server ? 1 : 0
  source = "./modules/compute"

  name                = "${local.name}-app"
  vpc_id              = module.network.vpc_id
  subnet_id           = module.network.public_subnet_ids[min(1, var.az_count - 1)]
  instance_type       = var.app_instance_type
  key_name            = var.ssh_key_name
  volume_size         = 60
  allocate_eip        = true
  ecr_repository_arns = module.ecr.repository_arns
  ecr_push            = false
  allow_eks_describe  = false
  ingress_rules = [
    { description = "SSH from admin", port = 22, cidrs = var.admin_cidrs },
    { description = "HTTP", port = 80, cidrs = var.app_allowed_cidrs },
    { description = "HTTPS", port = 443, cidrs = var.app_allowed_cidrs },
  ]
}

# ---- Jenkins may deploy to the cluster: read-only everywhere, write only in the nexvion namespace ----
resource "aws_eks_access_entry" "jenkins" {
  count = var.enable_jenkins ? 1 : 0

  cluster_name      = module.eks.cluster_name
  principal_arn     = module.jenkins[0].role_arn
  type              = "STANDARD"
  kubernetes_groups = ["nexvion-deployers"] # bound to the Role in kubernetes/rbac.yaml
}

resource "aws_eks_access_policy_association" "jenkins_view" {
  count = var.enable_jenkins ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = module.jenkins[0].role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jenkins]
}

# ---- Inventory for Ansible (ansible/inventory.<env>.ini, ignored by Git) ----
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.${var.environment}.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.tpl", {
    jenkins_ip       = var.enable_jenkins ? module.jenkins[0].public_ip : ""
    app_ip           = var.enable_app_server ? module.app_server[0].public_ip : ""
    ssh_key_name     = var.ssh_key_name
    aws_region       = var.aws_region
    ecr_registry     = split("/", module.ecr.repository_urls[0])[0]
    eks_cluster_name = module.eks.cluster_name
    cluster_version  = var.cluster_version
    environment      = var.environment
  })
}
