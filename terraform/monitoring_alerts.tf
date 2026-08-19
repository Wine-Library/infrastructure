# Turns the alerting rules in k8s/platform/monitoring/rules.yaml into an
# actual notification. GMP evaluates ClusterRules and writes results to Cloud
# Monitoring as prometheus.googleapis.com/ALERTS/gauge (value 1 while firing,
# label alertstate="firing") — see k8s/platform/README.md, "Alert delivery is
# not configured by any of this." This is that missing piece.

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Wine Library alerts"
  type         = "email"

  labels = {
    email_address = var.alert_notification_email
  }
}

# One policy covering every rule rather than one per alert: with a single
# person on call, five near-identical policies are more to maintain than the
# grouping below loses in specificity. group_by_fields keeps them as separate
# incidents in Cloud Monitoring even though there is one policy.
resource "google_monitoring_alert_policy" "wine_library_alerts" {
  project      = var.project_id
  display_name = "Wine Library — Prometheus rule firing"
  combiner     = "OR"

  conditions {
    display_name = "Any ClusterRules alert is firing"

    condition_threshold {
      filter          = "resource.type=\"prometheus_target\" AND metric.type=\"prometheus.googleapis.com/ALERTS/gauge\" AND metric.labels.alertstate=\"firing\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_NONE"
        group_by_fields      = ["metric.labels.alertname", "metric.labels.severity"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  # Re-notifies if the same alert is still firing after half an hour rather
  # than staying silent until it resolves.
  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "1800s"
    }
  }

  documentation {
    content   = "One of the rules in k8s/platform/monitoring/rules.yaml is firing. The alertname and severity (page/ticket) labels say which — check Grafana or `kubectl get clusterrules wine-library -o yaml` for the condition."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.service]
}
