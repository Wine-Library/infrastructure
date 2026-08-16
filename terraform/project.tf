resource "google_project" "main" {
  name            = "Wine Library"
  project_id      = var.project_id
  billing_account = var.billing_account
  deletion_policy = "PREVENT"
}
