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

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  cost_management_config {
    enabled = true
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "POD",
      "DEPLOYMENT",
      "STATEFULSET",
      "DAEMONSET",
      "HPA",
      "CADVISOR",
      "KUBELET",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  depends_on = [google_project_service.service]
}

resource "google_container_node_pool" "primary" {
  name     = "primary-2"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.main.name

  # Steady state was measured at ~640m CPU / ~4.2Gi of pod requests back when
  # dev and staging both ran; staging alone sits well under that. Two
  # e2-standard-2 carry it with room to spare - so the floor is 2, not 3. The
  # ceiling is 3 because the region's IN_USE_ADDRESSES quota is 4 and the
  # ingress load balancer holds one of those four addresses.
  autoscaling {
    min_node_count = 2
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Nodes get an ephemeral external IP each by default, so at the ceiling of 3
  # nodes plus the ingress address we are already at the quota of 4. A surge
  # upgrade (create-then-delete) would need a 5th address and fails - this is
  # what broke the 2026-08-16 node upgrade. Recreate-then-create stays within
  # the 4 we have.
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

    workload_metadata_config {
      mode = "GKE_METADATA"
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
