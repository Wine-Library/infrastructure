# Log and security audit

What gets logged, where it lives, what counts as an anomaly at this project's
scale, and how often someone should actually look.

## What's already collected, without any setup

GKE and GCP write two kinds of audit log by default — neither can be turned
off, and neither costs anything beyond the default 30-day retention:

- **Cloud Audit Logs — Admin Activity.** Every API call that creates, modifies
  or deletes a resource: IAM policy changes, service account key creation,
  firewall rules, the GKE cluster and node pool themselves. This is the
  primary source for "who changed what in the project."
- **Cloud Audit Logs — System Event.** Changes GCP makes on its own — node
  auto-repair, auto-upgrade. Useful for "why did a node disappear," not a
  security signal by itself.

Both are visible in Log Explorer (`resource.type="audited_resource"` or
filtering by `logName` containing `cloudaudit.googleapis.com`) without
enabling anything.

**Not collected by default, and deliberately not turned on:** Data Access
audit logs (who read what) and Kubernetes-level audit logs for read
operations. Both are high-volume and billed per log entry; turning them on
project-wide would be a real, ongoing line item for a threat this project
doesn't have (nobody's disputing who ran a `kubectl get`). If that changes —
a second engineer with cluster access whose actions need attribution, say —
revisit this rather than assume the current default still fits.

## What's watched actively

Two `google_logging_metric` resources (`terraform/audit.tf`) turn specific
Admin Activity events into an alert instead of rows waiting in Log Explorer:

| Metric | Fires on | Why this one |
| --- | --- | --- |
| `iam-policy-changes` | `SetIamPolicy` on the project | Who has access to the project changes rarely on a two-person infra. Any hit is worth a look. |
| `service-account-key-created` | `CreateServiceAccountKey` | Every service here authenticates via workload identity federation specifically so no long-lived key has to exist — see `DECISIONS.md`. A key being minted means either someone worked around that on purpose, or something is compromised and minting its own persistence. Either way this should never fire in normal operation. |

Both route to the same Cloud Monitoring alert policy and the same email as
the application alerts (`terraform/monitoring_alerts.tf`) — one inbox, not a
second channel to remember to check.

## What "anomaly" means here

This is a two-month portfolio project with effectively one operator, not a
production system with a real user base. That changes what counts as
suspicious:

- **Any** IAM policy change or service account key creation that wasn't just
  made on purpose, five minutes ago, by the person reading this — investigate.
  There's no legitimate background rate to distinguish from.
- A spike in `403`/`PERMISSION_DENIED` in the application's own logs
  (separate from the two metrics above — these are Cloud Audit Logs, not app
  logs) worth a look if it's not explained by a known bad deploy.
- Repeated `WineAppHighErrorRate` firings without a matching deploy or known
  incident — could be an application bug, could be someone probing the API.
  The ClusterRules alert (`k8s/platform/monitoring/rules.yaml`) already pages
  for this; the audit angle is checking ingress-nginx's access pattern
  (source IPs, request paths) when it does, not a separate detection.

## Review cadence

- **On alert** — the two log-based metrics above page immediately; that's
  the point of wiring them to a notification channel instead of a dashboard.
- **Weekly, five minutes** — skim Log Explorer for
  `protoPayload.methodName="SetIamPolicy" OR protoPayload.methodName=~"ServiceAccountKey"`
  over the past 7 days as a backstop in case an alert policy silently broke.
  Cross-check against the IAM members `terraform plan` expects — a member
  present in the console but not in `iam.tf` is unmanaged and worth
  explaining.
- **Before the portfolio review** — pull GitHub's own audit log
  (org Settings → Audit log, or `gh api orgs/Wine-Library/audit-log` for
  someone with org admin) for who has push access to the three repos and
  whether branch protection (see memory: `wine-library-branch-protection`)
  is still intact on `main`/`staging`. GitHub access is a second audit
  surface this document doesn't otherwise cover — GCP's audit logs don't see
  it at all.

## Where to look when something fires

1. The alert's `documentation` block (visible in the Cloud Monitoring
   incident) names which `google_logging_metric` fired.
2. Log Explorer, filtered to that metric's `filter` value from
   `terraform/audit.tf`, scoped to the incident's time window.
3. `protoPayload.authenticationInfo.principalEmail` on the matching log entry
   says who — a person's email, or a service account, either way it should
   match who/what was expected to be doing that at that time.
