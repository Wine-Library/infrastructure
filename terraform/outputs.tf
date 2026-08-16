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
