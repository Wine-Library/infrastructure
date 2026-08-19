# Backup destination for CloudNativePG's barmanObjectStore. GCS speaks the S3
# API, so an HMAC key stands in for the accessKeyId/secretAccessKey pair
# barman expects — no separate S3-compatible provider needed.

resource "google_storage_bucket" "wine_db_backups" {
  name          = "${var.project_id}-wine-db-backups"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true

  # Barman prunes old base backups itself per the Cluster's retentionPolicy
  # (7d, see k8s/base/db-cluster.yaml). This is a second, longer backstop in
  # case that ever stops running — not the primary retention mechanism.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.service]
}

resource "google_service_account" "wine_db_backup" {
  project      = var.project_id
  account_id   = "wine-db-backup"
  display_name = "CloudNativePG backup writer"
}

# objectAdmin, not objectCreator: barman also has to list and delete objects
# to enforce the retention policy and to run a restore.
resource "google_storage_bucket_iam_member" "wine_db_backup_writer" {
  bucket = google_storage_bucket.wine_db_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.wine_db_backup.email}"
}

resource "google_storage_hmac_key" "wine_db_backup" {
  service_account_email = google_service_account.wine_db_backup.email
}
