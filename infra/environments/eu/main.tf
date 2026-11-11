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

  region                 = "europe-west1"
  zone                   = "europe-west1-b"
  cluster_name           = "llmd-poc-eu"
  network_name           = "llmd-poc-vpc"
  subnet_name            = "llmd-poc-eu"
  pods_range_name        = "eu-gke-pods"
  services_range_name    = "eu-gke-services"
  master_ipv4_cidr_block = "172.16.0.16/28"
  service_account_id     = "llmd-poc-eu-sa"

  # P5 (2026-11-11): GPU pool enabled for Environment B (always-warm during
  # test windows per A16; scale to 0 outside windows).
  # Capacity ladder (2026-11-11): spot and on-demand g2-standard-8 both
  # exhausted in europe-west4-a -> try spot g2-standard-4 (separate capacity
  # pool; same 1x L4 24GB GPU, less host CPU/RAM).
  gpu_spot          = true
  gpu_machine_type  = "g2-standard-4"
  gpu_min_node_count = 1
  gpu_pool_enabled  = true

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
  region  = "europe-west1"
}
