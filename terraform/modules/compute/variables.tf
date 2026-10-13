variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "key_name" {
  type = string
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "allocate_eip" {
  description = "Attach an Elastic IP so the address survives stop/start."
  type        = bool
  default     = true
}

variable "ingress_rules" {
  description = "Inbound rules: description, port, allowed CIDRs."
  type = list(object({
    description = string
    port        = number
    cidrs       = list(string)
  }))
}

variable "ecr_repository_arns" {
  type    = list(string)
  default = []
}

variable "ecr_push" {
  description = "true = may push images (Jenkins), false = may only pull."
  type        = bool
  default     = false
}

variable "allow_eks_describe" {
  description = "Allow eks:DescribeCluster (needed for aws eks update-kubeconfig)."
  type        = bool
  default     = false
}
