variable "apis" {
  description = "Google APIs this infrastructure depends on directly. GCP enables further services transitively when these are enabled; those are not managed individually here."
  type        = set(string)
  default = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "sts.googleapis.com",
  ]
}

variable "billing_account" {
  description = "Billing account ID the project is linked to."
  type        = string
  default     = "010EF5-39FD45-37CA72"
}

variable "cluster_name" {
  description = "Name of the GKE Autopilot cluster."
  type        = string
  default     = "wine-library"
}

variable "deployer_display_name" {
  description = "Display name of the GitHub Actions deploy service account."
  type        = string
  default     = "GitHub Actions deployer"
}

variable "deployer_service_account_id" {
  description = "Account ID (local part of the email) of the GitHub Actions deploy service account."
  type        = string
  default     = "github-deployer"
}

variable "github_repository" {
  description = "GitHub repository, in owner/repo form, allowed to impersonate the deploy service account."
  type        = string
  default     = "Wine-Library/infrastructure"
}

variable "github_repository_owner" {
  description = "GitHub organization allowed to authenticate through the workload identity provider."
  type        = string
  default     = "Wine-Library"
}

variable "project_id" {
  description = "GCP project ID."
  type        = string
  default     = "wine-library-mate"
}

variable "project_number" {
  description = "GCP project number. Workload identity resource names are returned by Google in this numeric form, not the project ID."
  type        = string
  default     = "212393176266"
}

variable "region" {
  description = "Region the static address and workload identity pool live in."
  type        = string
  default     = "europe-central2"
}

variable "zone" {
  description = "Zone the GKE cluster lives in. Zonal rather than regional to keep the regional SSD_TOTAL_GB quota usable — a regional cluster's node pools span 3 zones and burn through it fast."
  type        = string
  default     = "europe-central2-a"
}

variable "static_address_name" {
  description = "Name of the static external IP reserved for the ingress load balancer."
  type        = string
  default     = "wine-ingress"
}

variable "workload_identity_pool_id" {
  description = "ID of the workload identity pool GitHub Actions authenticates through."
  type        = string
  default     = "github"
}

variable "workload_identity_pool_display_name" {
  description = "Display name of the workload identity pool."
  type        = string
  default     = "GitHub Actions"
}

variable "workload_identity_provider_id" {
  description = "ID of the OIDC provider inside the workload identity pool."
  type        = string
  default     = "github"
}
