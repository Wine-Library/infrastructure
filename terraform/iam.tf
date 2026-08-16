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
