variable "project_id" {
  type = string
}

variable "network_name" {
  description = "Name of the dedicated PoC VPC (one VPC hosts both regional clusters)"
  type        = string
  default     = "llmd-poc-vpc"
}

variable "subnets" {
  description = "One entry per regional cluster. All CIDRs must be non-overlapping across subnets and against the existing vllm-vpc ranges (10.0.0.0/20, 10.4.0.0/14, 10.8.0.0/20)."
  type = list(object({
    name                = string
    region              = string
    node_cidr           = string
    pods_range_name     = string
    pods_cidr           = string
    services_range_name = string
    services_cidr       = string
  }))
}
