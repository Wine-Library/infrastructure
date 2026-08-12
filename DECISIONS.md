# Decisions

Choices made where the brief left room, and why.

## Kustomize base + overlays instead of flat manifests

The brief described a flat, numbered file list with `namespace: dev` written into
every manifest. Three environments are planned, so that layout means three copies
of the same files drifting apart. `base/` holds namespace-free definitions and
each overlay supplies the differences.

`kubectl` ships with kustomize, so this adds no tooling. Apply with
`kubectl apply -k overlays/<env>`.

## Directory is `k8s/`, not `infra/`

The repository is already called `infrastructure`, so `infra/infra/...` would
read badly. Manifests live in `k8s/` to leave room for a `terraform/` sibling
when cluster provisioning gets codified.

## `prod` namespace declared before it is used

Prod arrives at the end of the project, replacing staging rather than joining it
— Autopilot capacity will not hold three environments at once. An empty
namespace costs nothing (Autopilot bills pod requests), so all four are declared
up front and the environment list is visible in one file.

The `prod` overlay is written but not applied yet. Its image tag is a placeholder
release tag.

## Dev runs one Postgres instance, staging and prod run two

Each environment has one audience. Dev belongs to the backend — it redeploys on
every merge and serves the API the frontend builds against, so its data churns
and nobody reads a replica. Staging is the stable build QA tests, which makes it
the sensible place for the analyst, so it carries the replica and Metabase. Prod
inherits both.

A standby in dev would spend Autopilot budget on a replica nobody queries.

## Metabase is a kustomize component, not part of base

Metabase belongs to staging and prod but not dev. Modelling it as an opt-in
component keeps the inclusion explicit in each overlay, instead of putting it in
base and deleting it back out with a patch.

Dashboards will not survive the staging-to-prod cutover on their own — Metabase
questions reference the IDs of the database they were built against. That is a
one-time rebuild for the analyst, noted in `k8s/README.md` rather than solved,
because the alternatives cost more than the rebuild does.

## Namespaces are applied separately from the overlays

Namespaces are cluster-scoped and shared, so they stay in a single
`namespaces.yaml` applied once rather than being duplicated into every overlay.

## Secret and operator steps are documented, not manifested

Creating the database secret and installing the CloudNativePG operator are
one-off `kubectl` commands that must not produce committed files — a secret
manifest with a real password in git defeats the point. Both live as commands in
`k8s/README.md`, so there is one place to read the apply order end to end.

## Backup configuration lives in the README, not as commented-out YAML

The brief asked for a commented-out `barmanObjectStore` block in the cluster
manifest. Fifteen lines of dead YAML in a live manifest is noise; the block sits
in `k8s/README.md` as a ready-to-paste overlay patch instead, alongside the note
that the same block targets Hetzner Object Storage.

## Connection string uses the short service name

`jdbc:postgresql://wine-db-rw:5432/wine_library` rather than the fully qualified
`wine-db-rw.dev.svc.cluster.local`. The application always sits in the same
namespace as its database, so the short name resolves correctly and the value
needs no per-overlay patch.

## Liquibase, not Flyway

The original brief specified Flyway; the backend shipped Liquibase. Both are
covered by the same course material and neither is wrong here, so the manifests
follow the backend rather than forcing a rewrite.

One operational difference matters. Flyway serialises through a PostgreSQL
advisory lock, released automatically when the session drops. Liquibase uses a
`DATABASECHANGELOGLOCK` row, which survives the pod that took it — a migration
interrupted by a killed pod leaves every later start hanging on the lock until
it is cleared by hand. The recovery statement is in `k8s/README.md`.

## Every environment sets a non-empty Liquibase context

Each overlay sets `LIQUIBASE_CONTEXTS` to its own name — `dev`, `staging`,
`prod` — and base defaults to `prod` so a new overlay that forgets the key gets
the restrictive behaviour rather than the permissive one.

The first attempt left it empty everywhere except dev, on the assumption that an
empty context filters contexted changesets out. Liquibase does the opposite: with
no contexts specified at runtime it runs everything, including changesets that
declare one. That would have put the seed accounts — whose passwords sit in a
public repository — into prod. An explicit per-environment value filters
correctly regardless of how the empty case is interpreted.

Verified on the live dev cluster: `databasechangelog` records
`02-fill-users-table-with-default-users` with `contexts = dev`, and the four seed
users exist in dev only.

## Application configuration comes from a generated ConfigMap

Non-secret settings — port, context path, database URL, JWT lifetimes and issuer,
Liquibase contexts — live in a `configMapGenerator` in base rather than as inline
`env` entries. Overlays override single keys with `behavior: merge` instead of
patching the container spec, which is how dev turns on the seed-data context.

The generator appends a content hash to the ConfigMap name and kustomize rewrites
the reference, so changing a value rolls the Deployment instead of leaving pods
running with stale configuration until someone restarts them.

Secrets deliberately do not use `secretGenerator`: that would put the values in
git. They are created with `kubectl create secret` and referenced by fixed name.

## Environment variable names follow the backend

The backend reads `DB_URL`, `DB_USERNAME` and `DB_PASSWORD` rather than Spring's
own `SPRING_DATASOURCE_*`, which would have needed no configuration at all. The
manifests adapt instead of asking for a rename — three lines here against a
change to a repository already in review.

## Probe paths are coupled to the context path

`SERVER_CONTEXT_PATH=/api/v1` shifts the actuator endpoints too, so the probes
target `/api/v1/actuator/health/...`. Plain kustomize cannot interpolate the
ConfigMap value into the probe path, so the two are kept in sync by hand and
flagged in `k8s/README.md`. Setting `management.server.port` on the backend
would remove the coupling and keep actuator off any future Ingress; worth doing
if the context path ever changes.

## Pinned image versions with an explicit staleness note

- `ghcr.io/cloudnative-pg/postgresql:17.10`
- `metabase/metabase:v0.63.2`
- CloudNativePG operator `1.30.0`

Pinned rather than `latest` so a pod restart cannot silently change the Postgres
major version. Verified against upstream releases on 2026-08-12; re-check before
the next cluster is built.

PostgreSQL 17 matches the major version the backend runs in its local
`docker-compose.yml`, so local behaviour and the cluster do not diverge. 18 is
available but would put the team's laptops and the cluster on different majors.

Metabase gets an explicit `-XX:MaxRAMPercentage=70.0`. It is a JVM application
under the same container-memory rules as the backend, and the JVM default of 25%
would leave roughly 256Mi of heap against the 1Gi limit — too tight for recent
Metabase versions. If it still OOMs, raise the limit to 2Gi rather than removing
the flag.

The brief's reference manifest used `metabase/metabase:latest`; a rolling tag
makes restarts non-reproducible, which is the opposite of what a portfolio
repository should demonstrate.

## Metabase keeps H2, but on a PersistentVolumeClaim

A dedicated Postgres database for Metabase costs a database, a secret and more
env wiring, so H2 stays. Running it on ephemeral container storage does not:
Autopilot reschedules pods during node upgrades on its own, so the analyst would
lose dashboards on a routine cluster event rather than an incident. A 1Gi PVC
removes that failure mode for the price of one object.

The Deployment therefore uses `strategy: Recreate` — the volume is ReadWriteOnce
and the default rolling update would deadlock waiting for a second pod to attach
it.

H2 on a volume is still single-writer and unbacked-up; moving to Postgres stays
the follow-up when prod goes up.

## Analyst grants use `ALTER DEFAULT PRIVILEGES FOR ROLE wine_app`

Default privileges attach to the role that creates the object. The statement is
run as the superuser through `kubectl exec`, but Liquibase creates tables as
`wine_app`, so omitting `FOR ROLE` would silently cover only superuser-created
tables. The analyst would see the tables that existed when the grant ran and
none that a later migration added — a failure that surfaces weeks later, as a
missing table rather than an error.

## Analyst password stored as a Kubernetes secret

The brief's SQL had a placeholder password inline. Generating it into a
`wine-db-analyst` secret keeps credential handling identical to the
application's and leaves nothing sensitive in the `.sql` file.

## Startup probe guards the migration, not the split probe paths

Both applications get a `startupProbe` with a 300 second budget. Until it
succeeds the liveness probe does not run at all, which is the only thing that
reliably stops a slow first boot — a long Liquibase migration on the backend, H2
initialisation on Metabase — from being killed halfway through. Delaying the
liveness probe with `initialDelaySeconds` was the earlier attempt and is not
equivalent: it picks a fixed deadline instead of waiting for the app to report
ready.

Readiness and liveness use the split `/actuator/health/readiness` and
`/actuator/health/liveness` endpoints rather than a shared `/actuator/health`,
which keeps a failing liveness check from being triggered by anything other than
the application itself. This requires
`management.endpoint.health.probes.enabled: true` in the backend config.

Note what this does not currently do: Spring Boot's readiness group contains only
`readinessState`, so a pod stays Ready while its database is unreachable. Adding
`management.endpoint.health.group.readiness.include=readinessState,db` on the
backend would pull unreachable-database pods out of the Service. Left off for
now — it is a one-line change whenever it is wanted.

## `imagePullPolicy: Always` in base, `IfNotPresent` in prod

dev and staging deploy the moving `dev` and `staging` tags. Kubernetes defaults
to `IfNotPresent` for any tag other than `latest`, so a node would keep serving a
cached image after CI pushed a new one under the same tag — the deploy would
appear to succeed and change nothing. Base sets `Always`; prod pins an immutable
release tag and patches the policy back to `IfNotPresent`.

## Pods run as non-root with no service account token

Neither application talks to the Kubernetes API, so
`automountServiceAccountToken: false` removes a token that could only ever be
misused. Both run with `runAsNonRoot`, dropped capabilities,
`allowPrivilegeEscalation: false` and the `RuntimeDefault` seccomp profile.

The backend is pinned to `runAsUser: 1000` because `eclipse-temurin` images
default to root and the deployment should not depend on the backend's Dockerfile
to fix that. Metabase is left to its image's own user with only `fsGroup: 2000`
set, which makes the volume writable through supplemental groups regardless of
the UID the image chose.

`readOnlyRootFilesystem` is deliberately not set. Spring writes to `/tmp` and
Metabase to its plugin directory, so enabling it needs `emptyDir` mounts that
were not worth adding this month.

## Services added for both Metabase and the application

The brief only asked for Deployments. Without a Service neither is reachable, so
each manifest carries its own `ClusterIP` Service. No Ingress — port-forward is
enough for now.

## Environment label is metadata-only

The `environment` label is applied without `includeSelectors`, so it never
reaches `spec.selector.matchLabels`. Deployment selectors are immutable after
creation; injecting a per-overlay label there would break the first update.

## Application image path is a placeholder

`ghcr.io/wine-library/backend` — the registry path is a guess until the backend's
CI publishes somewhere concrete. Needs confirming before the deployment is
applied for real.
