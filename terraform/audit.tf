# Cloud Audit Logs already record these events by default (Admin Activity
# logs cannot be disabled and are free) — nobody was looking at them. These
# turn two security-relevant event types into counted metrics and an alert,
# rather than rows waiting in Log Explorer for someone to think to query them.
# See SECURITY_AUDIT.md for the review process this feeds into.

resource "google_logging_metric" "iam_policy_changes" {
  project     = var.project_id
  name        = "iam-policy-changes"
  description = "IAM policy bindings changed on the project — who got access and when."
  filter      = <<-EOT
    protoPayload.methodName="SetIamPolicy"
    resource.type="project"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# Every service in this project authenticates via workload identity
# federation, deliberately, so that no long-lived key ever needs to exist —
# see DECISIONS.md. A key being minted for any service account is therefore
# always worth a look, not just a security-team nice-to-have.
resource "google_logging_metric" "service_account_key_created" {
  project     = var.project_id
  name        = "service-account-key-created"
  description = "A service account key was minted. This project uses workload identity everywhere, so this should never fire."
  filter      = <<-EOT
    protoPayload.methodName="google.iam.admin.v1.CreateServiceAccountKey"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "security_audit_events" {
  project      = var.project_id
  display_name = "Wine Library — security audit event"
  combiner     = "OR"

  conditions {
    display_name = "IAM policy changed"

    condition_threshold {
      filter          = "resource.type=\"project\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.iam_policy_changes.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  conditions {
    display_name = "Service account key created"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.service_account_key_created.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    content   = "An event in SECURITY_AUDIT.md's watch list happened. Find it in Log Explorer with the filter from the matching google_logging_metric in terraform/audit.tf, scoped to the time this fired."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.service]
}
