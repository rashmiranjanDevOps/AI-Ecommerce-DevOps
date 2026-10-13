# Production environment: resilient NAT, bigger nodes, nothing deleted by accident.
environment = "prod"
aws_region  = "ap-south-1"

vpc_cidr           = "10.30.0.0/16"
az_count           = 3
single_nat_gateway = false # one NAT gateway per zone

# Must be a version in STANDARD support today. Check with:
#   aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].[clusterVersion,endOfStandardSupportDate]" --output table
cluster_version     = "1.35"
node_instance_types = ["t3.large"]
node_desired_size   = 3
node_min_size       = 3
node_max_size       = 6

enable_jenkins    = false # use the Jenkins server of the dev environment
enable_app_server = false

ecr_force_delete = false
ecr_keep_images  = 50
