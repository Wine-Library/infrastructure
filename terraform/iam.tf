resource "google_service_account" "github_deployer" {
  project      = var.project_id
  account_id   = var.deployer_service_account_id
  display_name = var.deployer_display_name
}

# Grants only enough to fetch cluster credentials. Namespace-scoped
# permissions come from k8s/platform/deployer-rbac.yaml, applied via kubectl.
resource "google_project_iam_member" "github_deployer_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.github_deployer.email}"
}

resource "google_service_account" "grafana_datasource" {
  project      = var.project_id
  account_id   = var.grafana_datasource_service_account_id
  display_name = var.grafana_datasource_display_name
}

resource "google_project_iam_member" "grafana_datasource_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana_datasource.email}"
}


resource "google_service_account_iam_member" "grafana_datasource_workload_identity" {
  service_account_id = google_service_account.grafana_datasource.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/frontend]"
}

# The frontend proxy speaks Cloud Monitoring on Grafana's behalf, but nothing
# proxies BigQuery, so the Grafana pod itself needs to present as this same
# service account to query the billing export directly.
resource "google_service_account_iam_member" "grafana_datasource_workload_identity_grafana" {
  service_account_id = google_service_account.grafana_datasource.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/grafana]"
}

# The billing export dataset is created by hand, not by Terraform (see
# terraform/README.md), but the IAM binding on it is ordinary managed
# infrastructure like anything else here.
resource "google_bigquery_dataset_iam_member" "grafana_datasource_billing_viewer" {
  project    = var.project_id
  dataset_id = "billing_export"
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grafana_datasource.email}"
}

# BigQuery requires a jobUser grant on top of dataViewer — reading a table
# happens by running a query job, which is a separate permission.
resource "google_project_iam_member" "grafana_datasource_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grafana_datasource.email}"
}
