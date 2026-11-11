terraform {
  required_version = ">= 1.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.41.0"
    }
  }
}

# Adapted from vllm-gke infra/modules/vllm-cluster (MIT, © 2026 Iheb Besbes):
# parameterized zone/CIDRs/machine/accelerator/node counts; RAG pool removed;
# GPU pool behind gpu_pool_enabled (P5 toggles it without module edits).

# trivy:ignore:gcp-0051
# trivy:ignore:gcp-0056
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id

  network    = var.network_name
  subnetwork = var.subnet_name

  deletion_protection      = false
  remove_default_node_pool = true
  initial_node_count       = 1

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_ip_ranges
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "system_pool" {
  name     = "system-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  # Always-on: regional gateway, regional EPP (+ hub EPP in the US cluster), Prometheus
  node_count = var.system_node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.system_machine_type
    image_type   = "COS_CONTAINERD"

    metadata = {
      disable-legacy-endpoints = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_container_node_pool" "gpu_pool" {
  count = var.gpu_pool_enabled ? 1 : 0

  name     = "gpu-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  autoscaling {
    min_node_count = var.gpu_min_node_count
    max_node_count = var.gpu_max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # trivy:ignore:gcp-0048
  # trivy:ignore:gcp-0050
  # trivy:ignore:gcp-0054
  node_config {
    machine_type = var.gpu_machine_type

    spot = var.gpu_spot

    guest_accelerator {
      type  = var.gpu_accelerator_type
      count = var.gpu_accelerator_count
      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_service_account" "cluster_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for ${var.cluster_name} Workload Identity"
  project      = var.project_id
}

resource "google_service_account_iam_binding" "workload_identity_binding" {
  service_account_id = google_service_account.cluster_sa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.workload_identity_ksa}]"
  ]

  depends_on = [
    google_container_cluster.primary
  ]
}
