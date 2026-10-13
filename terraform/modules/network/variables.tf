variable "name" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for the subnet discovery tags."
  type        = string
}

variable "cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}
