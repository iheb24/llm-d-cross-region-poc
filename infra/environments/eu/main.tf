terraform {
  required_version = ">= 1.0.0"
  backend "gcs" {
    bucket = "project-tf-states"
    prefix = "llm-d-cross-region-poc/eu"
  }
}

provider "google" {
  project = var.project_id
}

module "cluster" {
  source     = "../../modules/cluster"
  project_id = var.project_id

  region                 = "europe-west4"
  zone                   = "europe-west4-a"
  cluster_name           = "llmd-poc-eu"
  network_name           = "llmd-poc-vpc"
  subnet_name            = "llmd-poc-eu"
  pods_range_name        = "eu-gke-pods"
  services_range_name    = "eu-gke-services"
  master_ipv4_cidr_block = "172.16.0.16/28"
  service_account_id     = "llmd-poc-eu-sa"

  # P2: system pool only. GPU pool is added at P5 (Environment B) via:
  #   gpu_pool_enabled = true
  gpu_pool_enabled = false

  authorized_ip_ranges = [
    {
      cidr_block   = "${var.my_public_ip}/32"
      display_name = "Operator machine"
    }
  ]
}

# Regional gateway address (independently reachable spoke, PLAN.md §4).
# Consumed by the Gateway Service at P3 and by the hub discovery file at P4.
resource "google_compute_address" "gateway" {
  name    = "llmd-poc-eu-gw"
  project = var.project_id
  region  = "europe-west4"
}
