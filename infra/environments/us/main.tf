terraform {
  required_version = ">= 1.0.0"
  backend "gcs" {
    bucket = "project-tf-states"
    prefix = "llm-d-cross-region-poc/us"
  }
}

provider "google" {
  project = var.project_id
}

module "cluster" {
  source     = "../../modules/cluster"
  project_id = var.project_id

  region                 = "us-central1"
  zone                   = "us-central1-a"
  cluster_name           = "llmd-poc-us"
  network_name           = "llmd-poc-vpc"
  subnet_name            = "llmd-poc-us"
  pods_range_name        = "us-gke-pods"
  services_range_name    = "us-gke-services"
  master_ipv4_cidr_block = "172.16.0.32/28"
  service_account_id     = "llmd-poc-us-sa"

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

# Regional gateway address (US spoke; also serves the hub colocated here).
resource "google_compute_address" "gateway" {
  name    = "llmd-poc-us-gw"
  project = var.project_id
  region  = "us-central1"
}

# Hub gateway address (client-facing entry point for hub-routed traffic).
resource "google_compute_address" "hub_gateway" {
  name    = "llmd-poc-hub-gw"
  project = var.project_id
  region  = "us-central1"
}
