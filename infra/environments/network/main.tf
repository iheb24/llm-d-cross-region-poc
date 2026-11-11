terraform {
  required_version = ">= 1.0.0"
  backend "gcs" {
    bucket = "project-tf-states"
    prefix = "llm-d-cross-region-poc/network"
  }
}

provider "google" {
  project = var.project_id
}

module "network" {
  source     = "../../modules/network"
  project_id = var.project_id

  # CIDR plan (PLAN.md §4): non-overlapping across both clusters and against
  # the existing vllm-vpc (10.0.0.0/20, 10.4.0.0/14, 10.8.0.0/20).
  subnets = [
    {
      name                = "llmd-poc-eu"
      region              = "europe-west1"
      node_cidr           = "10.10.0.0/20"
      pods_range_name     = "eu-gke-pods"
      pods_cidr           = "10.12.0.0/14"
      services_range_name = "eu-gke-services"
      services_cidr       = "10.18.0.0/20"
    },
    {
      name                = "llmd-poc-us"
      region              = "us-east1"
      node_cidr           = "10.20.0.0/20"
      pods_range_name     = "us-gke-pods"
      pods_cidr           = "10.24.0.0/14"
      services_range_name = "us-gke-services"
      services_cidr       = "10.28.0.0/20"
    },
  ]
}
