resource "google_container_cluster" "main" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = true

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {}

  depends_on = [google_project_service.service]
}

resource "google_container_node_pool" "primary" {
  name     = "primary-2"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.main.name

  autoscaling {
    min_node_count = 3
    max_node_count = 4
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Nodes get an ephemeral external IP each by default, and the region's
  # IN_USE_ADDRESSES quota is 4 - already exactly what min/max node count
  # uses at steady state. A surge upgrade (create-then-delete) needs a 5th
  # address and fails; recreate-then-create stays within the 4 we have.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 0
    max_unavailable = 1
  }

  node_config {
    machine_type = "e2-standard-2"
    disk_type    = "pd-standard"
    disk_size_gb = 30
    image_type   = "COS_CONTAINERD"

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }
}
