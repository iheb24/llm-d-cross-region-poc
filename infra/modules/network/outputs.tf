output "network_name" {
  value = google_compute_network.vpc.name
}

output "subnet_names" {
  value = { for name, s in google_compute_subnetwork.subnet : name => s.name }
}

output "subnet_regions" {
  value = { for name, s in google_compute_subnetwork.subnet : name => s.region }
}
