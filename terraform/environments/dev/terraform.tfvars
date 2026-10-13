# Development environment. Copy secret-free values here; keep personal values (IP, key name)
# in environments/dev/secret.tfvars, which is ignored by Git:
#   terraform plan -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars
environment = "dev"
aws_region  = "ap-south-1"

vpc_cidr           = "10.20.0.0/16"
az_count           = 2
single_nat_gateway = true # one NAT gateway: cheaper, not zone-resilient

# Must be a version in STANDARD support today. Check with:
#   aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].[clusterVersion,endOfStandardSupportDate]" --output table
cluster_version     = "1.35"
node_instance_types = ["t3.large"]
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 3

enable_jenkins    = true
enable_app_server = true

ecr_force_delete = true # dev only: lets "terraform destroy" remove repositories that contain images
