variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "my_public_ip" {
  description = "Operator public IP for master authorized networks (e.g., 203.0.113.5)"
  type        = string
}
