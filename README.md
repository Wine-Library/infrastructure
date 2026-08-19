# infrastructure

Infrastructure for the Wine Library project.

## Layout

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — one-page map of what's deployed and
  how it fits together, with a diagram.
- [`k8s/`](k8s/) — Kubernetes manifests as a kustomize base with one overlay per
  environment. Start with [`k8s/README.md`](k8s/README.md) for the apply order.
- [`terraform/`](terraform/) — everything under the cluster: project, APIs,
  the cluster itself, the static IP, workload identity. See
  [`terraform/README.md`](terraform/README.md).
- [`DECISIONS.md`](DECISIONS.md) — why things are the way they are.
- [`RECOVERY.md`](RECOVERY.md) — backup and restore procedure.
- [`SECURITY_AUDIT.md`](SECURITY_AUDIT.md) — what's logged and reviewed, and how often.

```bash
kubectl apply -k k8s/overlays/staging
```

## Stack

| Piece | Choice |
| --- | --- |
| Cluster | GKE, zonal standard (`europe-central2-a`) — Autopilot until 2026-08-16, see `DECISIONS.md` |
| Database | PostgreSQL via the CloudNativePG operator, in-cluster |
| Analytics | Metabase against a read-only replica |
| Application | Java 21 / Spring Boot 3.2, schema managed by Liquibase |

## Why in-cluster Postgres instead of Cloud SQL

The analyst needs a read replica, and the whole setup has to move between
providers as manifests. CloudNativePG manifests apply unchanged on any
Kubernetes cluster; a Cloud SQL setup would have to be rebuilt from scratch on
the next provider. Cluster provisioning and the backup endpoint are the only
provider-specific pieces.

## Environments

- `staging` — the shared integration target: automatic deploys from CI, stable
  build for QA, plus the analyst's Metabase
- `prod` — stands up at the end of the project, replacing staging

The `dev` environment was removed — see [`DECISIONS.md`](DECISIONS.md). Autopilot
capacity will not carry both remaining environments at once, so staging is
retired when prod comes up. Per-environment sizing is in
[`k8s/README.md`](k8s/README.md).

## Secrets

No credentials live in this repository. Database passwords are created directly
in the cluster with `kubectl create secret` and injected into pods via
`secretKeyRef`. See [`k8s/README.md`](k8s/README.md) for the exact commands.
