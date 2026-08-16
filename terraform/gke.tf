resource "google_container_cluster" "main" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  enable_autopilot = true

  # Client-side guard only: blocks `terraform destroy`/replace, no API call.
  deletion_protection = true

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {}

  lifecycle {
    # Autopilot manages node pools itself; nothing here should ever touch them.
    ignore_changes = [node_config]
  }

  depends_on = [google_project_service.service]
}
