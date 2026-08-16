resource "google_compute_address" "wine_ingress" {
  name    = var.static_address_name
  project = var.project_id
  region  = var.region
}
