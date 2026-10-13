variable "name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane network interfaces and the nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_disk_size" {
  type    = number
  default = 30
}

variable "log_retention_days" {
  type    = number
  default = 14
}
