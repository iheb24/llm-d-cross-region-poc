# Declared (previously manual gcloud call, 2026-11-12): the PoC evidence
# dashboard lives in terraform so teardown/rebuild stays declarative.
resource "google_monitoring_dashboard" "llmd_poc" {
  project        = var.project_id
  dashboard_json = file("${path.module}/../../../dashboards/llmd-poc.json")
}
