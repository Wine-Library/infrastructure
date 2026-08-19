# Platform components

Cluster-wide pieces that every environment shares. Installed once, before any
overlay. Upstream components are applied from their releases rather than
vendored here, the same way the CloudNativePG operator is.

Check the current versions before installing — both move quickly:
[ingress-nginx](https://github.com/kubernetes/ingress-nginx/releases) ·
[cert-manager](https://github.com/cert-manager/cert-manager/releases)

## Why an ingress controller rather than LoadBalancer services

A `type: LoadBalancer` service provisions one cloud load balancer each. One
ingress controller fronts every service in every namespace behind a single load
balancer, which is the difference between one line item and four.

It is also the portable choice. ingress-nginx runs on any Kubernetes cluster,
unlike GKE's own Ingress and Google-managed certificates, which are tied to
this provider.

## 1. Reserve a static IP

The load balancer's address ends up in DNS, so it must not change when the
service is recreated.

```bash
gcloud compute addresses create wine-ingress --region=europe-central2
```

```bash
gcloud compute addresses describe wine-ingress --region=europe-central2 --format='value(address)'
```

## 2. ingress-nginx

```bash
helm install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.service.loadBalancerIP=RESERVED_IP
```

Wait for the address to be assigned:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

## 3. DNS

Point the hostnames at the reserved address. One A record per environment:

| Record | Points to | Serves |
| --- | --- | --- |
| `staging` | reserved IP | staging frontend and API |
| `bi.staging` | reserved IP | Metabase |
| `grafana` | reserved IP | Grafana |
| `@` and `www` | reserved IP | prod, when it exists |

DNS has to resolve before certificates can be issued — Let's Encrypt validates by
fetching a token over HTTP from the hostname itself.

## 4. cert-manager

Install from the chart rather than the plain manifest, and set resource requests
explicitly:

```bash
helm install cert-manager cert-manager --repo https://charts.jetstack.io --namespace cert-manager --create-namespace --set crds.enabled=true --set global.leaderElection.namespace=cert-manager --set resources.requests.cpu=100m --set resources.requests.memory=128Mi --set webhook.resources.requests.cpu=100m --set webhook.resources.requests.memory=128Mi --set cainjector.resources.requests.cpu=100m --set cainjector.resources.requests.memory=128Mi --set startupapicheck.resources.requests.cpu=100m --set startupapicheck.resources.requests.memory=128Mi
```

`global.leaderElection.namespace` is required on Autopilot. cert-manager puts its
leader-election Lease in `kube-system` by default, and Autopilot's admission
controller refuses writes to that namespace:

```
leases.coordination.k8s.io is forbidden: GKE Warden authz
[denied by managed-namespaces-limitation]
```

The failure is indirect and easy to misread. cainjector never becomes leader, so
it never writes the CA bundle into the webhook configuration; every call to the
webhook then fails with `x509: certificate signed by unknown authority`, and the
install dies on its `startupapicheck` hook while all three pods sit there
`Running`. Confirm the injection worked rather than trusting pod status:

```bash
kubectl get mutatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
```

A few characters means empty. A working install returns something over a
thousand.

The requests are not optional here either. cert-manager's upstream manifests declare
none, and Autopilot substitutes its own default of 0.5 vCPU and 2 GiB per
container — roughly 1.5 vCPU and 6 GiB across the three deployments, for a
component that uses about 100Mi. That is enough to force a node scale-up, which
in a fresh project hits the regional `SSD_TOTAL_GB` quota, because every
Autopilot node carries a 100 GB boot disk.

```bash
kubectl rollout status -n cert-manager deployment/cert-manager-webhook --timeout=300s
```

Set a real address in [cluster-issuer.yaml](cluster-issuer.yaml) — Let's Encrypt
sends expiry warnings there — then:

```bash
kubectl apply -f k8s/platform/cluster-issuer.yaml
```

Two issuers are defined. `letsencrypt-staging` issues untrusted certificates
against a service with generous rate limits; `letsencrypt` issues real ones and
allows only a handful of failures per hostname per week. Debugging a
misconfigured HTTP-01 challenge against the production endpoint is how a hostname
gets locked out for a week.

`base/ingress.yaml` therefore points at `letsencrypt-staging`. Once a certificate
reaches `Ready` there — the browser will still warn, which is expected, the
issuing CA is untrusted — switch the annotation to `letsencrypt`, reapply, and
delete the old secret so a real certificate is requested:

```bash
kubectl delete secret wine-tls -n staging
```

## 5. Verify

After an overlay is applied, the certificate should reach `Ready`:

```bash
kubectl get certificate -n staging
```

If it stays `False`, the order and challenge objects carry the reason:

```bash
kubectl describe challenge -n staging
```

Almost always one of: DNS not resolving yet, the A record pointing somewhere
else, or the hostname in the Ingress not matching the record.

## 6. Monitoring

Metrics are stored by Google Managed Prometheus and drawn by a Grafana that
keeps nothing of its own — see [DECISIONS.md](../../DECISIONS.md) for why, and
the collectors in `gmp-system` are already running, installed with the cluster.
What follows connects things to them.

The order matters in one place only: the `frontend` proxy cannot authenticate
until Workload Identity is on the cluster, and turning that on recreates every
node.

**Terraform first.** `workload_identity_config`, `workload_metadata_config`,
`cost_management_config` and the trimmed `monitoring_config` all live in
`terraform/gke.tf`, and the service account Grafana reads Cloud Monitoring
through is in `terraform/iam.tf`.

```bash
terraform -chdir=terraform apply
```

Node recreation is the slow part — one node at a time, because `max_surge = 0`
keeps the pool inside the `IN_USE_ADDRESSES` quota of 4. Do it on its own, not
alongside a deploy, and confirm before continuing:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.cloud\.google\.com/gke-metadata-server-enabled}{"\n"}{end}'
```

**Metrics from the ingress controller.** Off by default, and the only
measurement of the product taken from outside the application:

```bash
helm upgrade ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace ingress-nginx --reuse-values --set controller.metrics.enabled=true
```

```bash
kubectl apply -f k8s/platform/ingress-nginx-metrics.yaml
```

**The Grafana admin secret**, by hand — `*-secret.yaml` is gitignored and this
never becomes a file:

```bash
kubectl create secret generic grafana-admin -n monitoring --from-literal=username=admin --from-literal=password="$(openssl rand -base64 24)"
```

Read it back once and put it in the password manager; there is no second
chance short of resetting it.

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d
```

**Grafana and the query proxy:**

```bash
kubectl apply -k k8s/platform/monitoring
```

```bash
kubectl apply -f k8s/platform/monitoring/rules.yaml
```

`rules.yaml` is applied separately because `ClusterRules` is cluster-scoped and
kustomize, which has no schema for the CRD, would stamp a namespace onto it.

**Verify** the proxy answers before opening the UI — a datasource that cannot
authenticate looks identical to one that has no data:

```bash
kubectl exec -n monitoring deploy/grafana -- wget -qO- 'http://frontend.monitoring.svc:9090/api/v1/query?query=up' | head -c 400
```

A `403` here means the two halves of the Workload Identity binding do not agree:
the annotation on the `frontend` service account and
`google_service_account_iam_member.grafana_datasource_workload_identity`.

**Alert delivery is not configured by any of this.** The rules evaluate inside
Managed Prometheus and write to `prometheus.googleapis.com/ALERTS`; turning that
into a message to a person is an alerting policy plus a notification channel in
Cloud Monitoring, created per rule in the console.

## When a pod stays Pending

Two Autopilot behaviours make this confusing, and both showed up while this
cluster was being built.

**Anything without resource requests gets Autopilot's defaults** — 0.5 vCPU and
2 GiB per container, regardless of what it actually needs. Third-party manifests
frequently ship without requests, so they arrive far larger than expected and
push the cluster into a scale-up. Set requests explicitly on anything installed
from upstream.

**`gke-system-balloon-pod` reserves most of a node** — it appears in
`kubectl describe node` holding several vCPU and tens of GiB, which makes
`Allocated resources` read close to 100% on an almost-empty cluster. It is a
low-priority placeholder that Autopilot evicts when real work arrives, so it can
be ignored when reading allocation.

The genuine ceiling is quota. Each node carries a 100 GB boot disk against the
regional `SSD_TOTAL_GB` limit, which starts at 250 GB — two nodes and change.
Current usage:

```bash
gcloud compute regions describe europe-central2 --format="flattened(quotas)" | grep -A2 SSD_TOTAL_GB
```

Raising it goes through IAM & Admin → Quotas in the console. Note that free trial
accounts cannot request increases; that needs the billing account upgraded to
paid first, which keeps the remaining credits.

## Deployer access

[deployer-rbac.yaml](deployer-rbac.yaml) grants the `github-deployer` Google
service account the rights the deploy pipeline needs inside the `staging`
namespace.
Applied by an administrator, once:

```bash
kubectl apply -f k8s/platform/deployer-rbac.yaml
```

It deliberately lives here rather than in the deployment overlay. A pipeline that
applies its own Role can grant itself anything by merging one pull request, so
the grant has to sit outside what the pipeline applies. Kubernetes pushes in the
same direction: it refuses to let a subject create a Role carrying permissions
that subject does not already hold.

The role covers only what the overlay contains, read-only on pods for
`rollout status`, and no `delete` — a bad manifest can spoil an object but cannot
remove a database along with its volume. Secrets are absent entirely, so a
compromised runner cannot read the database password or the JWT signing key.

GCP IAM and Kubernetes RBAC answer different questions here. The service account
holds `roles/container.clusterViewer` project-wide, which only lets it fetch
cluster credentials; everything it may actually do is decided by this Role, in
one namespace.

## Routing

Each environment gets one hostname, with the API under a path prefix rather than
its own subdomain:

```
staging.<domain>/          frontend
staging.<domain>/api/...   backend
```

Same-origin, so the browser sends no preflight and the backend needs no CORS
configuration at all. The backend's context path is already `/api/v1`, so the
prefix passes through unchanged and no rewrite annotation is needed.

Metabase gets its own hostname instead of a path. It is the analyst's tool rather
than part of the product, and a separate host keeps it out of the application's
origin.
