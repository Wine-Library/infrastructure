# terraform

Codifies what sits under `k8s/` and was created by hand: the project, its
billing link, the APIs the cluster needs, the Autopilot cluster itself, the
`wine-ingress` static IP, and the workload identity setup GitHub Actions
authenticates through.

## What this does not cover

- The `default` VPC/subnetwork — referenced by name, not managed here.
- Namespace-scoped deploy permissions — those are `k8s/platform/deployer-rbac.yaml`,
  applied via `kubectl`, not IAM.
- APIs beyond the curated list in `variables.tf` — GCP enables a long tail of
  dependent services on its own (e.g. the whole BigQuery family, pulled in by
  the billing export); those aren't Terraform's concern.

## First run: importing, not creating

The cluster already has live data in it. Every resource here has a matching
`import` block, so the first `apply` should attach to what already exists
rather than create anything new.

```bash
terraform init
terraform plan
```

Read the plan before applying anything. Expect entries like
`# google_project.main will be imported` — that's the point. What to watch
for instead: any line under an imported resource that says
`~ update in-place` for an attribute you didn't expect. That means the config
doesn't quite match reality yet, and applying would change the live resource,
not just record it in state. Fix the `.tf` file so it matches what's actually
there, re-plan, and only apply once every action is `import` (or, for
`google_container_cluster.main`, the expected `deletion_protection: false → true`
noted below).

```bash
terraform apply
```

Once the apply succeeds, the `import { }` blocks are no longer needed —
they're harmless to leave (already-imported resources make them no-ops), but
removing them keeps the code honest about being ordinary managed
infrastructure from here on.

## Expected first-apply change

`deletion_protection = true` on `google_container_cluster.main` is a
Terraform-side guard, not a GCP API field — setting it doesn't call the API
or touch the running cluster, it only stops `terraform destroy` (or a
replace-triggering change) from going through. The cluster currently has
this unset, so the first apply flips it in Terraform's state. Nothing on the
cluster itself changes.

## State

State is local (`terraform.tfstate`, gitignored) — fine solo, not once more
than one person runs `apply`. Move to a GCS backend before that happens.

## Variables

Defaults in `variables.tf` match what's live right now. Override via
`terraform.tfvars` (gitignored, see `terraform.tfvars.example`) rather than
editing defaults, so the file stays a record of what's actually deployed.
