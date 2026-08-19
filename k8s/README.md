# Kubernetes manifests

Postgres runs inside the cluster via the CloudNativePG operator. Nothing here is
GCP-specific, so the same manifests apply to any Kubernetes cluster.

## Layout

```
k8s/
├── namespaces.yaml              cluster-wide, applied once
├── base/                        shared definitions, no namespace
├── components/metabase/         opt-in, included per environment
├── overlays/{dev,staging,prod}/ environment differences
└── sql/                         one-off statements run against the primary
```

Manifests in `base/` carry no namespace and no environment-specific values.
Each overlay sets the namespace, the image tag and whatever it needs to differ.
Adding an environment means adding one overlay; removing one means deleting a
directory.

## Environments

| | dev | staging | prod |
| --- | --- | --- | --- |
| Purpose | backend pushes and sees the result; serves the API the frontend develops against | QA testing and analytics | live |
| Users | backend, frontend | QA, analyst | everyone |
| Postgres instances | 1 | 2 (primary + replica) | 2 (primary + replica) |
| Storage | 5Gi | 5Gi | 10Gi |
| App replicas | 1 | 1 | 2 |
| Metabase | no | yes | yes |
| Image tag | `dev` | `staging` | release tag |
| Image pull | always | always | if not present |
| Lifetime | the project | until prod comes up | months |

Dev runs a single Postgres instance: nothing reads from a replica there, and the
data churns with every merge. The analyst works against staging, where the build
is stable and QA has already exercised it — so staging carries the replica and
the Metabase instance.

Autopilot capacity will not carry three environments at once. Staging is retired
when prod comes up, and Metabase moves with the analyst; its overlay stays in
git as the reference for how a throwaway environment was shaped.

Metabase questions are bound to the IDs of the database they were built on, so
dashboards do not follow the analyst from staging to prod automatically. Plan
one rebuild at the cutover, and check whether serialization is available in the
Metabase OSS build before assuming an export path exists.

## Apply order

### 1. Namespaces

```bash
kubectl apply -f namespaces.yaml
```

### 2. CloudNativePG operator

Check the [latest release](https://github.com/cloudnative-pg/cloudnative-pg/releases)
first — the version below goes stale quickly.

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml
```

Verify:

```bash
kubectl get deployment -n cnpg-system cnpg-controller-manager
```

### 3. Database secret

Created in the cluster, never committed. CloudNativePG can generate credentials
itself, but an explicit secret keeps the connection string predictable across
recreates. Repeat per namespace.

```bash
kubectl create secret generic wine-db-app --namespace dev --from-literal=username=wine_app --from-literal=password="$(openssl rand -base64 24)"
```

Read the password back when you need it:

```bash
kubectl get secret wine-db-app -n dev -o jsonpath='{.data.password}' | base64 -d
```

The application also needs a JWT signing key. Rotating it invalidates every
issued token, so generate it once per namespace and leave it alone. Repeat per
namespace (dev, staging, prod), swapping `--namespace`:

```bash
kubectl create secret generic wine-app-jwt --namespace dev --from-literal=secret="$(openssl rand -base64 48)"
```

The application also sends mail (verification, password reset) and calls an
external wines API. Both are real third-party credentials, not generated —
substitute actual values before running. Repeat per namespace, and use
distinct values per environment rather than copying dev's:

```bash
kubectl create secret generic wine-app-mail --namespace dev --from-literal=username='<gmail address>' --from-literal=password='<gmail app password>'
kubectl create secret generic wine-app-wines-api --namespace dev --from-literal=key='<wines API key>'
```

Nothing in the application currently reads `wines.api.key` — the property has
no injection point in the backend, so the secret only exists to satisfy Spring
at startup (the property has no default). A placeholder value is fine until
that's resolved.

### 4. Environment

Review the rendered output before applying:

```bash
kubectl kustomize overlays/dev
```

Apply:

```bash
kubectl apply -k overlays/dev
```

This creates the Postgres cluster, the application and — in dev and prod —
Metabase. The application pods crash-loop until the backend image exists; that
is expected before the first backend release.

Verify the database (the `cnpg` plugin shows roles and replication lag):

```bash
kubectl get cluster -n dev wine-db
kubectl cnpg status wine-db -n dev
```

### 5. Analyst user

Read-only role for Metabase — the analyst must not connect as the database
owner. The role replicates to the standby automatically.

Generate a password and store it as a secret first. Repeat per namespace that
runs Metabase (staging, and prod once it exists — see the environments table
above):

```bash
kubectl create secret generic wine-db-analyst --namespace dev --from-literal=username=analyst --from-literal=password="$(openssl rand -base64 24)"
```

No pod consumes this secret — it is where the generated password is kept so it
can be re-read later. The analyst types it into the Metabase UI once.

Then run [sql/analyst-user.sql](sql/analyst-user.sql) on the primary,
substituting that password:

```bash
kubectl exec -n dev -it wine-db-1 -- psql -d wine_library
```

### 6. Metabase source

Metabase runs in staging, and in prod once it exists. Reach the UI locally:

```bash
kubectl port-forward -n staging svc/metabase 3000:80
```

In the UI, add a Postgres source pointing at `wine-db-ro`, port `5432`, database
`wine_library`, user `analyst`.

Metabase stores its own settings in an embedded H2 database on a 1Gi
PersistentVolumeClaim, so dashboards survive the pod being rescheduled — which
Autopilot does on its own during node upgrades. The Deployment uses the
`Recreate` strategy because the volume is ReadWriteOnce and a rolling update
would deadlock on it.

H2 on a volume is still single-writer and not backed up. Moving Metabase onto a
small dedicated Postgres database is the follow-up when prod goes up.

## Services created by the operator

CloudNativePG provisions three services per cluster. Connecting to the right one
matters:

| Service | Purpose | Consumer |
| --- | --- | --- |
| `wine-db-rw` | read-write, always the primary | backend application |
| `wine-db-ro` | read-only, load-balanced across replicas | Metabase / analyst |
| `wine-db-r` | any instance including the primary | unused |

The application resolves `wine-db-rw` by short name within its own namespace, so
the connection string is identical in every environment:

```
jdbc:postgresql://wine-db-rw:5432/wine_library
```

The application talks to the primary only. Analytics runs against the replica,
bypassing the application entirely — no second datasource in Spring.

The physical replica is strictly read-only, so the analyst cannot create tables
or materialized views on it. Dashboards and ad-hoc SQL work fine. A writable
analytics layer would need logical replication into a separate database — out of
scope for now.

## Backups

Not configured yet. Once a bucket and a `gcs-backup-creds` secret exist, add a
patch to the target overlay:

```yaml
patches:
  - target:
      kind: Cluster
      name: wine-db
    patch: |
      - op: add
        path: /spec/backup
        value:
          barmanObjectStore:
            destinationPath: "s3://wine-db-backups/"
            endpointURL: "https://storage.googleapis.com"
            s3Credentials:
              accessKeyId:
                name: gcs-backup-creds
                key: ACCESS_KEY_ID
              secretAccessKey:
                name: gcs-backup-creds
                key: SECRET_ACCESS_KEY
          retentionPolicy: "7d"
```

GCS is S3-compatible, so the same block points at any other S3-compatible
provider by swapping `endpointURL` and the bucket.

## Resource limits and the JVM

The application caps memory at 768Mi, which pairs with
`-XX:MaxRAMPercentage=75.0` in the backend Dockerfile (~576Mi heap, the rest for
metaspace, thread stacks and GC). If pods restart with OOMKilled, raise the limit
in `base/app.yaml` rather than dropping the JVM flag.

## The contract with the backend image

The deployment matches the backend as of pull request 1. These are the points
where the two sides have to agree; each one fails loudly rather than silently,
but they are cheaper to get right up front.

**Port 8090 behind context path `/api/v1`.** Set by `SERVER_PORT` and
`SERVER_CONTEXT_PATH` in the ConfigMap. Application traffic only — the context
path no longer affects the probes.

**Port 9090 for actuator.** The image has to set `management.server.port=9090`,
`management.endpoints.web.exposure.include=health,prometheus` and carry
`micrometer-registry-prometheus`. The management server is a second connector
and does not inherit the context path, so health lives at
`/actuator/health/...` and metrics at `/actuator/prometheus`, both at the root
of 9090. The probes and the `PodMonitoring` in `base/podmonitoring.yaml` both
depend on this; an image without the setting fails its probes and the rollout
stalls on the old pod. Nothing routes to 9090 from the Ingress, which is the
point: on 8090 the metrics endpoint would be public.

**Health endpoints reachable without a token.** The probes are unauthenticated
HTTP requests from the kubelet. `/actuator/health/**` has to be `permitAll` in
the Spring Security chain, and `management.endpoint.health.probes.enabled=true`
has to be set or the readiness and liveness paths return 404. With the endpoint
open, `show-details` must not be `always` — it would publish the database host,
user and pool state to anyone who can reach the port.

**Environment variables.** `DB_URL`, `SERVER_PORT`, `SERVER_CONTEXT_PATH`,
`LIQUIBASE_CONTEXTS`, `FRONTEND_URL` and the non-secret `JWT_*` settings come
from the `wine-app-config` ConfigMap. `DB_USERNAME` and `DB_PASSWORD` come from
the `wine-db-app` secret, `JWT_SECRET` from `wine-app-jwt`, `MAIL_USERNAME` and
`MAIL_PASSWORD` from `wine-app-mail`, `WINES_API_KEY` from `wine-app-wines-api`.
Secrets are never generated by kustomize — they are created in the cluster by
hand. All four are required: their properties in `application.properties` have
no default, so a missing secret fails the pod at startup with an unresolved
placeholder, not at the point a feature is actually used.

**Heap capped against the pod limit.** The Dockerfile has to pass
`-XX:MaxRAMPercentage`. Without it the JVM sizes its heap against the node's
memory, not the 768Mi container limit, and the pod is OOMKilled under load.

**Runs as UID 1000.** Pods are `runAsNonRoot` with `runAsUser: 1000`, which
overrides whatever user the image declares — `eclipse-temurin` images default to
root, so this matters. The jar is world-readable after `COPY`, and `/tmp` (where
Tomcat writes) is world-writable, so no Dockerfile change is needed. Adding an
explicit `USER` to the Dockerfile is still good practice.

**Mutable tags are pulled every start.** dev and staging deploy the moving `dev`
and `staging` tags, so `imagePullPolicy: Always` is set — without it a node
would keep serving a cached image after CI pushed a new one. Prod pins a release
tag and uses `IfNotPresent`.

**Seed data is gated on a Liquibase context.** The changeset that inserts default
users carries `context: dev`, and each overlay sets `LIQUIBASE_CONTEXTS` to its
own environment name. The value must never be left empty: Liquibase runs every
changeset when no context is given at runtime, including the contexted ones, so
an empty value would put the seed accounts into prod rather than keep them out.

## Migrations

Liquibase runs inside the application pod at startup, against the primary
through `wine-db-rw`. There is no separate migration Job. The replica receives
the schema through physical WAL replication, so nothing is applied to it
directly, and roles created on the primary appear there too.

The startup probe allows 300 seconds for boot plus migrations before the
liveness probe engages, so a slow migration cannot restart the pod halfway.
PostgreSQL has transactional DDL, so a migration that does get interrupted rolls
back cleanly rather than leaving a half-applied schema.

The lock is the part worth knowing about. Liquibase serialises migrations
through a `DATABASECHANGELOGLOCK` row rather than a session-scoped advisory
lock, so a pod killed mid-migration leaves the lock held and every later start
waits on it forever. Symptom: pods stuck in startup with no progress in the log
after `Waiting for changelog lock`. Clear it on the primary:

```sql
UPDATE databasechangeloglock SET locked = false, lockedby = null, lockgranted = null WHERE id = 1;
```

Prod runs two application replicas, so both start Liquibase at once — the second
waits for the first, which is normal and counts against the startup budget.
Rolling updates also run the old and new versions against the same schema for a
few seconds, so a migration must not break the version still being replaced:
add columns nullable, and drop or rename in a later release.

## Readiness checklist

- [ ] Operator running in `cnpg-system`
- [ ] `wine-db-app`, `wine-app-jwt`, `wine-app-mail` and `wine-app-wines-api` secrets created per namespace, none in git
- [ ] `wine-db` cluster healthy, replica streaming with near-zero lag
- [ ] Backend image published and reachable at the path in `base/app.yaml`
- [ ] Backend serves `/actuator/health/readiness` on port 9090 without a token
- [ ] `wine-app` pods ready, no OOMKilled restarts under load
- [ ] Seed users absent from staging and prod
- [ ] `analyst` read-only user created, and visible on tables added by later migrations
- [ ] Metabase running and connected to `wine-db-ro` as `analyst`
- [ ] GCS backup configured (optional, by end of month)
