output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "zone" {
  value = google_container_cluster.primary.location
}

output "endpoint" {
  value = google_container_cluster.primary.endpoint
}

output "service_account_email" {
  value = google_service_account.cluster_sa.email
}
