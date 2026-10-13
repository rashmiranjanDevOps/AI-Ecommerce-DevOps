variable "project" {
  description = "Project name, used as a prefix for every resource."
  type        = string
  default     = "nexvion"
}

variable "environment" {
  description = "Environment name (dev or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

# ---------- network ----------
variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use (2 or 3)."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap, dev) or one per AZ (resilient, prod)."
  type        = bool
  default     = true
}

# ---------- access ----------
variable "admin_cidrs" {
  description = "Your public IP range(s) in CIDR form, e.g. [\"203.0.113.10/32\"]. Allowed to SSH and open the Jenkins UI. Must not be 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs must list at least one address range and must not contain 0.0.0.0/0."
  }
}

variable "eks_public_access_cidrs" {
  description = "Who may reach the Kubernetes API from the internet. Restrict to your own IP in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for the Jenkins and application servers."
  type        = string
}

variable "webhook_cidrs" {
  description = "Extra CIDRs allowed to reach Jenkins on port 8080 (GitHub webhook IPs from https://api.github.com/meta, field 'hooks')."
  type        = list(string)
  default     = []
}

# ---------- kubernetes ----------
variable "cluster_version" {
  description = "Kubernetes version of the EKS cluster. Use a version in STANDARD support (extended support costs about 6x more and old versions cannot be created). Check: aws eks describe-cluster-versions --query 'clusterVersions[?status==`STANDARD_SUPPORT`].[clusterVersion,endOfStandardSupportDate]' --output table"
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "Instance types of the worker nodes. t3.large (8 GB) fits the app plus monitoring and ELK."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

# ---------- servers ----------
variable "enable_jenkins" {
  description = "Create the Jenkins server."
  type        = bool
  default     = true
}

variable "enable_app_server" {
  description = "Create the single-server Docker Compose host (app + monitoring + ELK)."
  type        = bool
  default     = true
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "app_instance_type" {
  description = "ELK needs at least 4 GB of memory."
  type        = string
  default     = "t3.large"
}

variable "app_allowed_cidrs" {
  description = "Who may open the web site on the Docker host (ports 80/443)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------- registry ----------
variable "ecr_keep_images" {
  description = "How many tagged images to keep in each ECR repository."
  type        = number
  default     = 20
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete repositories that still contain images (use true for dev only)."
  type        = bool
  default     = false
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
