variable "project_id" {
  type = string
}

variable "zone" {
  description = "Zone for the zonal cluster and its node pools"
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods, must match the subnet definition in the network environment"
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services, must match the subnet definition in the network environment"
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = "Control-plane /28, must not overlap the other PoC cluster or vllm-gke (172.16.0.0/28)"
  type        = string
}

variable "authorized_ip_ranges" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "system_machine_type" {
  description = "Machine type for the always-on system node pool (gateway, EPP, Prometheus)"
  type        = string
  default     = "e2-standard-4"
}

variable "system_node_count" {
  type    = number
  default = 1
}

variable "gpu_pool_enabled" {
  description = "False during P2-P4 (simulator phases); enabled at P5 (Environment B)"
  type        = bool
  default     = false
}

variable "gpu_machine_type" {
  type    = string
  default = "g2-standard-8"
}

variable "gpu_accelerator_type" {
  type    = string
  default = "nvidia-l4"
}

variable "gpu_accelerator_count" {
  type    = number
  default = 1
}

variable "gpu_min_node_count" {
  type    = number
  default = 0
}

variable "gpu_max_node_count" {
  type    = number
  default = 1
}

variable "gpu_spot" {
  description = "Spot capacity is the reliable way to get an L4; preemption is recorded as an environmental event (risk R14)"
  type        = bool
  default     = true
}

variable "service_account_id" {
  description = "GCP service account ID for this cluster's nodes (unique per cluster)"
  type        = string
}

variable "workload_identity_ksa" {
  description = "namespaced/name of the Kubernetes service account bound to the GCP SA for model-server pods"
  type        = string
  default     = "llmd-serving/model-server-ksa"
}
