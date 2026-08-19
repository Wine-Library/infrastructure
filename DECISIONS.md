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
that the same block targets any other S3-compatible provider.

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

## One ingress controller, not a LoadBalancer per service

`type: LoadBalancer` provisions a cloud load balancer per service — backend,
Metabase, frontend, per environment. ingress-nginx puts all of them behind one.
Against a $300 trial that is the difference between one line item and several.

It is also the portable choice: ingress-nginx runs on any cluster, unlike GKE
Ingress and Google-managed certificates, which would have to be rebuilt on a
different provider — the reason the original brief ruled them out.

The load balancer's address is a reserved static IP rather than an ephemeral one,
because it is what DNS points at.

## Frontend and API share a hostname, split by path

Each environment answers on one host, with the API under `/api` rather than on
its own subdomain:

```
dev.<domain>/          frontend
dev.<domain>/api/...   backend
```

Same-origin, so the browser sends no preflight and the backend needs no CORS
configuration — which is why its `.cors(disable)` never became a problem. The
backend's context path is already `/api/v1`, so the prefix passes through with no
rewrite annotation.

Metabase gets its own hostname instead of a path: it is the analyst's tool, not
part of the product, and a separate origin keeps it outside the application's.

## Wine images go to Cloudflare R2, served from `img.wine-library.xyz`

Product images need object storage, and the choice follows the same reasoning that
picked CloudNativePG over Cloud SQL: staying provider-agnostic where it costs
nothing extra. R2 belongs to no cloud provider, so it needs no manifest changes
if the cluster ever moves. A GCS bucket would have to be copied and re-pointed.

Egress is free on R2, which is what makes it cheaper than S3 for a workload that
is almost entirely reads. The free tier — 10 GB stored, 1M class A and 10M class B
operations a month, counted per account rather than per bucket — covers a
catalogue this size several times over.

Traffic goes through a custom domain rather than the `r2.dev` development URL.
`r2.dev` is rate limited and not cached at the edge, and leaving it on beside a
custom domain keeps a second public entrance to the bucket that nobody watches. It
stays disabled.

The hostname is a subdomain, not the apex. `wine-library.xyz` is where the prod
frontend goes, and a custom domain there would put a proxied record in front of the
bucket: the ingress could not claim the name, and cert-manager's HTTP-01 challenge
would be answered by R2 instead of by the cluster.

Credentials are an R2 API token scoped to the single `wine-images` bucket with
object read and write, kept in a `wine-app-r2` secret created by hand, exactly as
`wine-db-app` and `wine-app-jwt` are. The default of "all buckets in this account,
including newly created buckets" would have handed the application access to the
database backup bucket that does not exist yet.

Nothing references any of this yet. The bucket, the hostname and the token exist;
the manifests gain `R2_ENDPOINT`, `R2_BUCKET` and `R2_PUBLIC_URL` in the generated
ConfigMap and two `secretKeyRef` entries once the backend has an upload path.
Wiring configuration into a deployment that ignores it would only make the first
real test ambiguous.

## Upstream components are installed from charts with explicit resources

ingress-nginx and cert-manager go in through Helm with resource requests set,
rather than through their plain release manifests. Neither declares requests
upstream, and Autopilot substitutes 0.5 vCPU and 2 GiB per container when they
are missing — cert-manager alone reserved about 1.5 vCPU and 6 GiB that way, for
a component that uses roughly 100Mi.

That was not merely wasteful: it forced a node scale-up, which failed against the
regional `SSD_TOTAL_GB` quota, since every Autopilot node carries a 100 GB boot
disk and a new project starts with 250 GB. Two nodes and a 5 GB volume already
sit at 205 GB.

The CloudNativePG operator stays on its release manifest — it declares its own
requests, so Autopilot has nothing to substitute.

cert-manager additionally needs `global.leaderElection.namespace=cert-manager`.
Its default is `kube-system`, which Autopilot makes read-only, so cainjector
never acquires its lease, never injects the webhook CA bundle, and every webhook
call fails on an untrusted certificate — while all its pods report `Running`.
Both settings are documented next to the install command in
`k8s/platform/README.md`, because neither failure names its own cause.

## Certificates come from Let's Encrypt via cert-manager

HTTP-01 challenges rather than DNS-01, because a challenge served through the
ingress needs no DNS provider credentials in the cluster. The cost is that
wildcard certificates are not possible, which does not matter for a handful of
known hostnames.

Two ClusterIssuers exist. Point an Ingress at `letsencrypt-staging` first: the
production endpoint allows only a few failures per hostname per week, and
debugging a misconfigured challenge against it locks the hostname out.

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

## Actuator listens on its own port, not behind the context path

Superseded the arrangement where `SERVER_CONTEXT_PATH=/api/v1` shifted the
actuator endpoints along with everything else and the probes had to track it by
hand. The backend now sets `management.server.port=9090`, so actuator sits on a
second connector at the root of its own port and the probes target
`/actuator/health/...` there.

What forced it was not the coupling but exposure. The Ingress routes `/api` into
the `wine-app` service, and the application's context path is `/api/v1`, so
everything actuator served was already public — `/api/v1/actuator/health`
answered 200 to the internet. Adding a Prometheus endpoint on that port would
have published endpoint names, library versions and request statistics with it.
Nothing routes to 9090, so it is reachable from inside the cluster and nowhere
else.

The cost is that the two repositories have to move together: an image without
the setting fails probes on 9090, and an image with it fails probes on 8090.
Between the two merges the old pod keeps serving — `maxUnavailable` rounds to
zero at one replica — so the failure mode is a stalled rollout, not an outage.

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

## Terraform manages a curated API list, not everything `gcloud` shows enabled

The project has 38 services enabled; most got there as automatic dependencies
of `container.googleapis.com` or as a side effect of setting up billing export
(the whole BigQuery family, `analyticshub`, `dataform`, `dataplex`). `terraform/`
only declares the handful the cluster and the deploy pipeline directly need —
`compute`, `container`, `iam`, `iamcredentials`, `sts`, `logging`, `monitoring`.
Trying to own the rest would mean fighting GCP's own dependency enablement on
every plan, for services nothing here actually calls.

## `dev` requests are patched below base, `staging` and `prod` are not

Base sets 250m/512Mi for `wine-app` and `wine-db` — sized for something that
takes real traffic. `dev` only serves the frontend's local development against
a single-instance database with no concurrent users, so its overlay drops
requests to 100m/320Mi and 100m/256Mi. Limits stay at the base value — only the
scheduling reservation shrinks, not the ceiling, so a runaway dev process still
gets killed at the same threshold as before.

The point is capacity on the two already-provisioned nodes, not per-pod tuning:
staging is about to add a second `wine-db` instance plus Metabase, and the
regional `SSD_TOTAL_GB` quota has room for roughly one more Autopilot node —
each carries a fixed 100 GB boot disk. Freeing dev's reserved-but-unused
capacity buys headroom without touching that quota.

## Terraform state stays local for now

`terraform/` has no remote backend yet — state is a gitignored file on whoever
runs `apply`. That's fine while it's one person; the day a second person needs
to run it, state has to move to a GCS bucket first, or two applies will race
each other. Not set up preemptively because it's a new bucket to provision,
and this pass was about capturing what already exists, not adding to it.

## Managed Prometheus stores the metrics, Grafana only draws them

The alternative was kube-prometheus-stack, and its values file lived at
`k8s/platform/monitoring-values.yaml` for a while without ever being installed.
It is recorded here and deleted rather than kept: an unapplied manifest in the
tree costs someone half a day of "why is this not running" later.

The numbers decided it. kube-prometheus-stack asks for roughly 1.75Gi plus a 5Gi
volume, which on two `e2-standard-2` nodes means a third one — measured at
$0.0812 per hour, so $59/month, not the $40 a price list suggests. Managed
Prometheus samples cost $10–16/month and are already on the bill: the collectors
have been running and ingesting since the cluster was built, and until now
nothing consumed what they collected. Retention is 24 months against three days
on a disk we would own, and it survived the cluster being recreated on
2026-08-16, which a PVC would not have.

What we give up is Alertmanager, replaced by the `Rules` CRD writing back into
Cloud Monitoring, and independence from Google — the same argument that chose
CloudNativePG points the other way here, and loses to the node price.

The bill is now a function of cardinality, which is why the scrape interval is
60s rather than 30s everywhere, why the ingress controller's `path` label is
dropped, and why the endpoint latency panel is a `topk(10)`. Halving an interval
or keeping one high-cardinality label doubles a line item as surely as adding a
target does.

## Metrics components are trimmed, but not to the point of blindness

GKE enables eleven monitoring components by default. Three are gone:
`DCGM` exports GPU metrics and its DaemonSet has zero pods on a cluster with no
GPU nodes — it was assumed to be waste on the bill and turned out to cost
exactly nothing, which is a different reason to drop it; `JOBSET` describes a
workload type nothing here runs; `STORAGE` duplicates what CNPG already reports
about the only volumes that matter.

`CADVISOR` and `KUBELET` stay, although they are the expensive pair. Container
CPU and memory come from them and from nothing else — kube-state-metrics reports
what a pod *requested*, not what it uses, so cutting them to save samples would
leave the cluster dashboard showing reservations and calling them consumption.

`cost_management_config` is enabled in the same block. It labels the BigQuery
billing export with namespace and workload, which is the only way to say what
dev costs versus staging. It was on for the Autopilot cluster and was lost when
this one was created; the export has carried no namespace breakdown since
2026-08-17.

## The Grafana datasource authenticates through Workload Identity

Grafana queries Cloud Monitoring through the prometheus-engine frontend proxy,
which has to present Google credentials. The node pool already carries the
`monitoring` OAuth scope, so the proxy could simply borrow the node's service
account and work today with no cluster change at all.

Workload Identity was worth the disruption anyway. Borrowing the node identity
grants those credentials to every pod scheduled on that node, including anything
a future dependency drags in; binding one Kubernetes service account to one
Google service account with `roles/monitoring.viewer` grants read-only metrics
access to exactly one workload, with no key material anywhere.

The disruption is real: `GKE_METADATA` on the node pool recreates every node. It
stays inside the `IN_USE_ADDRESSES` quota of 4 because `max_surge = 0` replaces
them one at a time, and it is applied as its own change, not folded into a
deploy.

## The `dev` environment is removed; staging is the only live environment

Recorded 19 August 2026.

`dev` existed so the backend could push to `development` and immediately see the
result, and so the frontend had an API to develop against. Both audiences moved
to staging in practice — the frontend points at `staging.wine-library.xyz` and
the backend's own integration checks run there — which left `dev` a third
Postgres instance, a third application pod and a third frontend pod serving
nobody.

That is not free. Autopilot bills the reservation, not the usage, and the node
pool floor of 2 was sized against `dev` plus staging. Removing `dev` gives back
its CPU and memory reservation and its 5Gi volume, which matters against a fixed
trial credit rather than an open budget.

The namespace was deleted outright rather than scaled to zero. A scaled-to-zero
environment still holds its PersistentVolumeClaim, still shows up in every
`kubectl get -A`, and still invites someone to bring it back by accident. The
seed data made deletion cheap: `dev` was the only environment carrying the
Liquibase `dev` context, so nothing in it was worth keeping, and it was already
recreated from scratch on every merge.

What went with it: `k8s/overlays/dev/`, the `dev` namespace, the `Deploy dev` and
`Sync dev image` workflows, and the `backend-image-published` repository-dispatch
trigger that only `Deploy dev` listened for. The deployer Role and RoleBinding in
`k8s/platform/deployer-rbac.yaml` moved from the `dev` namespace to `staging`,
since staging is now the namespace CI deploys into.

The Liquibase `dev` context stays in the backend changelog. No overlay passes it
any more, so the seed users are never inserted — which is the behaviour wanted in
staging and prod anyway. Deleting the changeset is the backend's call, not this
repository's.

Earlier decisions in this file that reason about `dev` are left as written. They
record why the environment was shaped the way it was, and rewriting them would
erase the reasoning rather than update it.

## Staging deploys track `main`, not a branch of its own

Recorded 19 August 2026.

Pull request 8 gave each environment its own branch: `Deploy dev` fired on pushes
to `development`, `Deploy staging` on pushes to `staging`. With two environments
that bought something real — the backend could land work on `development` and see
it in `dev` without touching what QA was testing in staging.

One environment does not need that. The branch became a second place to remember
to push, and it silently went stale: at the point `dev` was removed, `staging`
was sitting nine days behind `main`, still carrying the pre-Managed-Prometheus
manifests. Deploying it would have rolled Grafana and the monitoring stack back.
A deploy branch that nobody pushes is worse than no deploy branch, because it
looks like a working promotion path.

So `Deploy staging` now fires on pushes to `main` under `k8s/**`, and the
`development` and `staging` branches are deleted. Promotion to prod does not need
a branch either: prod pins a release tag in its overlay, so the tag is the
promotion mechanism and the deploy is a `workflow_dispatch` against `main`.

The scheduled workflows depended on this without it being obvious. GitHub runs
`schedule` and `repository_dispatch` triggers only from the default branch, so
`Sync staging image` was always running from `main` regardless of which branch
the deploy tracked — and `Sync dev image`'s cron on a non-default branch would
never have fired at all.
