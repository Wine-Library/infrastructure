# Backup and recovery

> **Status: draft, not yet exercised.** The commands below are believed
> correct — they follow CloudNativePG's documented recovery path — but nobody
> has run them against a real backup yet. A backup nobody has restored from is
> an assumption, not a plan. Run the drill in [Testing this plan](#testing-this-plan)
> and replace this notice with the date and result once it's done.

## What's backed up

CloudNativePG's `barmanObjectStore` integration, configured in
`k8s/base/db-cluster.yaml`. Two things land in the bucket continuously, not
just on a schedule:

- **WAL archiving** — every completed WAL segment, streamed to object storage
  as it's produced. This is what makes point-in-time recovery possible, not
  just "restore to the last backup."
- **Base backups** — a full physical copy of the data directory. CloudNativePG
  takes one automatically on a schedule (see `k8s/README.md` for the current
  cadence); a specific backup can also be requested on demand — see
  [Taking an on-demand backup](#taking-an-on-demand-backup) below.

Retention is 7 days (`retentionPolicy: "7d"` in `db-cluster.yaml`). Backups
older than that are pruned by barman itself; the bucket's own 30-day lifecycle
rule (`terraform/backup.tf`) is a second, longer backstop in case pruning ever
stops running, not the primary retention mechanism.

Staging and prod write to separate subfolders of one bucket
(`wine-library-mate-wine-db-backups`) — see the `destinationPath` patch in
each overlay's `kustomization.yaml`. Restoring one environment never touches
the other's data.

## What this does not cover

- **Metabase's own settings** (dashboards, saved questions) — these live in
  an embedded H2 database on a PVC, not in Postgres, and are not backed up by
  any of this. See `k8s/README.md` for the existing caveat about that volume.
- **The cluster itself** — this is database recovery, not infrastructure
  recovery. Losing the GKE cluster is a `terraform apply` plus
  `kubectl apply -k`, not covered here.

## Recovery scenarios

### A replica pod is lost

No action. CloudNativePG reschedules it and it re-streams from the primary.
Confirm with `kubectl cnpg status wine-db -n <namespace>` — replication lag
should return to near-zero within a few minutes.

### The primary pod is lost

CloudNativePG promotes the replica automatically; this is not a restore-from-
backup scenario. Confirm the new primary:

```bash
kubectl cnpg status wine-db -n <namespace>
```

The old primary's pod is recreated as a new replica once it comes back. If
there is no replica (a single-instance cluster, which is prod's current
patch — see `overlays/prod/kustomization.yaml`), this **is** a restore
scenario: skip to [Point-in-time recovery](#point-in-time-recovery-bad-data-or-a-bad-migration).

### Point-in-time recovery (bad data or a bad migration)

The scenario the WAL archive exists for: a migration or a bad write corrupted
data, and the fix is to go back to a timestamp before it happened. This
restores into a **new** Cluster object alongside the original — the broken
cluster keeps running throughout, so there is something to fall back to if
the restore itself goes wrong.

1. Pick a recovery point. `wine-db-1` is any running instance in the cluster
   being restored *from*, not the target:

   ```bash
   kubectl exec -n <namespace> wine-db-1 -- psql -c \
     "SELECT pg_walfile_name(pg_current_wal_lsn());"
   ```

   In practice the target time comes from knowing when the bad migration or
   bad write happened — a deploy timestamp, an incident report — not from
   this query. Use UTC.

2. Create the recovery cluster:

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: wine-db-restore
     namespace: <namespace>
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:17.10
     storage:
       size: 5Gi
     bootstrap:
       recovery:
         source: wine-db-backup
         recoveryTarget:
           targetTime: "2026-08-19 14:30:00+00"
     externalClusters:
       - name: wine-db-backup
         barmanObjectStore:
           destinationPath: "s3://wine-library-mate-wine-db-backups/<namespace>/"
           endpointURL: "https://storage.googleapis.com"
           s3Credentials:
             accessKeyId:
               name: gcs-backup-creds
               key: ACCESS_KEY_ID
             secretAccessKey:
               name: gcs-backup-creds
               key: SECRET_ACCESS_KEY
   ```

   Omit `recoveryTarget` entirely to restore to the latest available WAL
   instead of a specific time.

   ```bash
   kubectl apply -f wine-db-restore.yaml
   kubectl cnpg status wine-db-restore -n <namespace>
   ```

3. **Verify before cutting over.** Port-forward and check the data actually
   looks right — row counts, the specific record that was corrupted, whatever
   is relevant to the incident:

   ```bash
   kubectl exec -n <namespace> wine-db-restore-1 -- psql -d wine_library
   ```

4. Cut the application over. There is no built-in swap for this — point
   `wine-app` at the restored cluster by editing `DB_URL` in the
   `wine-app-config` ConfigMap to `wine-db-restore-rw`, or rename the Cluster
   objects (delete the broken one, rename `wine-db-restore` to `wine-db`) if
   the restored data should permanently replace the original. Renaming is
   simpler for anything downstream (Metabase, the analyst role) that already
   points at the `wine-db-*` service names.

5. Once cut over and confirmed stable, delete whichever cluster lost —
   normally the broken original, once its data is no longer needed for
   comparison.

### The whole namespace is gone

Recreate the namespace, secrets (`wine-db-app`, `wine-app-jwt`,
`wine-app-mail`, `wine-app-wines-api`, `wine-db-analyst`, `gcs-backup-creds`
— per `k8s/README.md`), then apply the recovery Cluster from
[Point-in-time recovery](#point-in-time-recovery-bad-data-or-a-bad-migration)
instead of the normal `db-cluster.yaml` as the first thing in the namespace.
Everything else (`k8s apply -k overlays/<env>`) follows normally once the
database exists and is verified.

## Taking an on-demand backup

Before a risky migration, rather than waiting for the schedule:

```bash
kubectl cnpg backup wine-db -n <namespace>
```

## Testing this plan

Not yet done. Do this on staging, not prod, and only once staging has data
worth the exercise:

1. Take an on-demand backup.
2. Write a row somewhere identifiable (`INSERT INTO wines ...` with an
   obvious marker value).
3. Run the [point-in-time recovery](#point-in-time-recovery-bad-data-or-a-bad-migration)
   steps, targeting a time before step 2.
4. Confirm the marker row is **absent** from `wine-db-restore` — that's the
   proof the target time actually took effect, not just that a backup
   restored at all.
5. Record how long steps 2–4 took here, and fix anything in this document
   that didn't match reality.
