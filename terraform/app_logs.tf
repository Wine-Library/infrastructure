# wine-app logs plain text to stdout (no structured JSON, no explicit
# severity), so GKE's default stream-based severity heuristic can't tell an
# exception apart from a normal request log line. Matching the level Spring
# Boot's default Logback pattern prints ("... ERROR ... ") is the only
# reliable signal without changing the app's logging config.
resource "google_logging_metric" "wine_app_errors" {
  project     = var.project_id
  name        = "wine-app-errors"
  description = "wine-app logged an ERROR-level line — exceptions and handled failures surfaced in application logs, distinct from the edge-level 5xx rate."
  filter      = <<-EOT
    resource.type="k8s_container"
    resource.labels.container_name="wine-app"
    textPayload:" ERROR "
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      key = "namespace"
    }
  }

  label_extractors = {
    "namespace" = "EXTRACT(resource.labels.namespace_name)"
  }
}
