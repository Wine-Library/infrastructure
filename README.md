# infrastructure

Infrastructure for the Wine Library project.

## Layout

- [`k8s/`](k8s/) — Kubernetes manifests as a kustomize base with one overlay per
  environment. Start with [`k8s/README.md`](k8s/README.md) for the apply order.

```bash
kubectl apply -k k8s/overlays/dev
```

## Stack

| Piece | Choice |
| --- | --- |
| Cluster | GKE Autopilot |
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

- `dev` — automatic deploys from CI; serves the API the frontend develops against
- `staging` — stable build for QA, plus the analyst's Metabase; promoted by tag
- `prod` — stands up at the end of the project, replacing staging

Autopilot capacity will not carry all three at once, so staging is retired when
prod comes up. Per-environment sizing is in [`k8s/README.md`](k8s/README.md).

## Secrets

No credentials live in this repository. Database passwords are created directly
in the cluster with `kubectl create secret` and injected into pods via
`secretKeyRef`. See [`k8s/README.md`](k8s/README.md) for the exact commands.
