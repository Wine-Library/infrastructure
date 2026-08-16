resource "google_project_service" "service" {
  for_each = var.apis

  project = var.project_id
  service = each.value

  # This project's APIs stay enabled even if the resource is ever removed
  # from state; a live cluster depends on them.
  disable_on_destroy = false
}
