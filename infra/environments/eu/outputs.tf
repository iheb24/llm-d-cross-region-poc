output "cluster_name" {
  value = module.cluster.cluster_name
}

output "zone" {
  value = module.cluster.zone
}

output "gateway_ip" {
  description = "Reserved regional gateway address (EU spoke)"
  value       = google_compute_address.gateway.address
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${module.cluster.cluster_name} --zone ${module.cluster.zone} --project ${var.project_id}"
}
