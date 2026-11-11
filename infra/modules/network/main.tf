terraform {
  required_version = ">= 1.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.41.0"
    }
  }
}

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}

# trivy:ignore:gcp-0029
# trivy:ignore:gcp-0076
resource "google_compute_subnetwork" "subnet" {
  for_each = { for s in var.subnets : s.name => s }

  name                     = each.value.name
  project                  = var.project_id
  region                   = each.value.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = each.value.node_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = each.value.pods_range_name
    ip_cidr_range = each.value.pods_cidr
  }

  secondary_ip_range {
    range_name    = each.value.services_range_name
    ip_cidr_range = each.value.services_cidr
  }
}

resource "google_compute_router" "router" {
  for_each = { for s in var.subnets : s.region => s }

  name    = "${var.network_name}-router-${each.key}"
  project = var.project_id
  region  = each.key
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  for_each = google_compute_router.router

  name                               = "${var.network_name}-nat-${each.key}"
  project                            = var.project_id
  region                             = each.key
  router                             = each.value.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
