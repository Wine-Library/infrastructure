output "cluster_endpoint" {
  description = "GKE control plane endpoint."
  value       = google_container_cluster.main.endpoint
}

output "github_deployer_email" {
  description = "Email of the service account GitHub Actions authenticates as."
  value       = google_service_account.github_deployer.email
}

output "static_ip_address" {
  description = "Reserved external IP for the ingress load balancer."
  value       = google_compute_address.wine_ingress.address
}

output "workload_identity_provider" {
  description = "Full identifier to paste into workload_identity_provider in workflow files."
  value       = "projects/${var.project_number}/locations/global/workloadIdentityPools/${var.workload_identity_pool_id}/providers/${var.workload_identity_provider_id}"
}

output "wine_db_backup_bucket" {
  description = "GCS bucket barmanObjectStore writes base backups and WAL to."
  value       = google_storage_bucket.wine_db_backups.name
}

output "wine_db_backup_access_id" {
  description = "HMAC access key ID — the ACCESS_KEY_ID half of the gcs-backup-creds secret. See RECOVERY.md."
  value       = google_storage_hmac_key.wine_db_backup.access_id
}

output "wine_db_backup_secret" {
  description = "HMAC secret — the SECRET_ACCESS_KEY half of the gcs-backup-creds secret. Only ever printed via `terraform output -raw`, never logged."
  value       = google_storage_hmac_key.wine_db_backup.secret
  sensitive   = true
}
