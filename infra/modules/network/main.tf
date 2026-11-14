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

  # CKV_GCP_26/61: flow logs feed the WAN-egress cost measurement (PLAN.md §10)
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = each.value.pods_range_name
    ip_cidr_range = each.value.pods_cidr
  }

  secondary_ip_range {
    range_name    = each.value.services_range_name
    ip_cidr_range = each.value.services_cidr
  }
}

# Declared (previously manual, 2026-11-13): hub's cross-cluster EPP metrics
# scrape (B3). Both pod ranges may reach regional metrics NodePorts.
resource "google_compute_firewall" "xcluster_metrics" {
  name        = "llmd-poc-xcluster-metrics"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "PoC B3: cross-cluster EPP metrics scrape (hub <-> regional NodePorts)"
  priority    = 900

  allow {
    protocol = "tcp"
    ports    = ["9090", "30090"]
  }

  source_ranges = [for s in var.subnets : s.pods_cidr]
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
