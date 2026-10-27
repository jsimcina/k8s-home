# Shared Postgres: disaster recovery

How to get the shared `postgres` CloudNativePG cluster (namespace `database`)
back from its backups, and how to prove those backups restore.

This covers the shared cluster only. Kritika has its own cluster
(`kritika-postgres`), and etcd is backed up separately (see
[What this does not cover](#what-this-does-not-cover)).

## What is protected, and where

| | |
| --- | --- |
| Object store | Cloudflare R2 bucket `cnpg`, through the `cfr2` `ObjectStore` ([`objectstore.yaml`](../kubernetes/apps/database/cloudnative-pg/cluster/objectstore.yaml)) |
| Archive name | `serverName: postgres18` in [`cluster.yaml`](../kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml) (`plugins`) |
| Base backups | Daily, by the `postgres` `ScheduledBackup` (`@daily`, `method: plugin`) |
| WAL | Archived continuously by the barman-cloud plugin |
| Retention | `30d` |
| Credentials | `cloudnative-pg-secret`, built by an `ExternalSecret` from the 1Password item `cloudnativepg` (`R2_KEY_ID`, `R2_APP_KEY`, plus the superuser fields) |

RPO is the WAL archive lag, normally a few minutes. RTO is **not measured**:
restoring about 9 GB of bzip2-compressed backup plus a day of WAL has not been
timed. Procedure B below doubles as the drill that measures it.

Signals that backups are healthy (all from the rules in
[`prometheusrules.yaml`](../kubernetes/apps/database/cloudnative-pg/cluster/prometheusrules.yaml)):

- `LastFailedArchiveTime`: WAL archiving is failing.
- `BackupStale`: no successful base backup in 36 hours.
- `BackupFailed`: the latest backup failed and none has succeeded since.
- `BackupMetricsAbsent`: the plugin stopped reporting, so the two above can't fire.

`kubectl get backups -n database` and the
`barman_cloud_cloudnative_pg_io_first_recoverability_point` metric show the
oldest point you can restore to (about 30 days back).

## Which procedure

| Situation | What to do |
| --- | --- |
| One instance or its volume is lost | Nothing. CNPG rebuilds it from the primary. Watch `kubectl cnpg status postgres -n database`. |
| The primary is lost | Nothing. CNPG fails over. Same check. |
| All instances or all volumes are lost, or the `Cluster` was deleted | [Procedure A](#procedure-a-full-rebuild) |
| Bad data: a dropped table, a bad migration | [Procedure B](#procedure-b-point-in-time-recovery-into-a-separate-cluster). Recover into a *new* cluster, never over the live one. |
| You want to know whether the backups work | Procedure B, as a drill |

## Before any restore

A rebuild needs these, and the Flux `dependsOn` chain brings them up in order:
`external-secrets` and the `onepassword-connect` store (for the R2 keys),
`cert-manager` (barman-cloud plugin), the plugin itself
(`cloudnative-pg-barman-cloud`), and Miroir's `miroir-local` StorageClass
(`miroir-config`). On a full cluster rebuild, let Flux converge before editing
anything.

If 1Password is unavailable, the R2 keys can't be rebuilt from the cluster. Keep
a copy of the `cloudnativepg` item's R2 fields somewhere that does not depend on
the cluster.

## Procedure A: full rebuild

Use this when the `Cluster` or all its volumes are gone. It is
delete-and-recover-in-place, the same shape as the
[Miroir migration](miroir-cnpg-migration.md), and it means downtime.

1. **Pick the restore point.** The archive to restore from is the live
   `serverName` (`postgres18` today). If the `Backup` objects still exist,
   `kubectl get backups -n database` lists them. If they are gone, list the
   bucket with the R2 keys from 1Password
   (`aws s3 ls s3://cnpg/postgres18/base/ --endpoint-url <R2 endpoint>`).
   Without a target, recovery uses the latest backup plus all WAL.

2. **Stop Flux fighting you.** The Kustomizations live in the `database`
   namespace, not `flux-system`:

    ```bash
    flux suspend kustomization cloudnative-pg-cluster -n database
    ```

3. **Remove what's left**, if anything, and confirm the volumes are gone:

    ```bash
    kubectl delete cluster postgres -n database
    kubectl get pvc -n database -l cnpg.io/cluster=postgres
    ```

4. **Rotate the archive name and point recovery at the old one.** A new
   cluster must not archive into a `serverName` that holds a different system
   identifier, so the rebuilt cluster writes to a **new** name and recovers
   **from** the current one. Edit `cluster.yaml`:

    ```diff
           parameters: &barmanParameters
             barmanObjectName: cfr2
    -        serverName: postgres18
    +        serverName: postgres18-v2
       bootstrap:
         recovery:
    -      source: postgres18-v1
    -      recoveryTarget:
    -        backupID: "20260908T000000"
    +      source: postgres18
       externalClusters:
    -    - name: postgres18-v1
    +    - name: postgres18
           plugin:
             isWALArchiver: true
             name: barman-cloud.cloudnative-pg.io
             parameters:
               barmanObjectName: cfr2
    -          serverName: postgres18-v1
    +          serverName: postgres18
    ```

    To restore to a point in time instead of the latest, add
    `recoveryTarget: { targetTime: "2026-10-27 12:00:00+00" }` under
    `recovery`. Everything else in the file (storage, affinity, the
    `vchord` extension and `shared_preload_libraries`, the image catalog) stays
    as it is: the restored data needs the same Postgres major and the same
    extension build.

    Next time, the names advance one step again (`postgres18-v3` writes,
    `postgres18-v2` is the source).

5. **Commit, then resume Flux:**

    ```bash
    flux resume kustomization cloudnative-pg-cluster -n database
    ```

6. **Watch it come back.** A `postgres-1-full-recovery` pod runs first:

    ```bash
    kubectl get pods -n database -l cnpg.io/cluster=postgres -w
    kubectl cnpg status postgres -n database
    ```

    Wait for `Cluster in healthy state` with all three instances streaming.

7. **Validate**, then start a fresh backup on the new archive:

    ```bash
    kubectl cnpg psql postgres -n database -- -c "\dx"
    kubectl cnpg psql postgres -n database -- -c "SELECT datname FROM pg_database WHERE NOT datistemplate;"
    ```

    You should see `vchord` and the application databases. The
    `cloudnative-pg-databases` Kustomization re-adopts the roles and databases
    and re-applies their passwords from 1Password. Pin the backup to the
    primary: without `target: primary` CNPG can send it to a standby and fail
    with a hot-standby recovery conflict.

    ```bash
    kubectl apply -f - <<'EOF'
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: postgres-after-restore
      namespace: database
    spec:
      cluster:
        name: postgres
      target: primary
      method: plugin
      pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
    EOF
    ```

8. **Tidy up later.** The old archive (`postgres18`) is untouched, so it is also
   the rollback. As far as I know, retention only prunes the archive a cluster
   is writing to, so an old archive is not removed automatically; check the
   bucket before relying on that either way. Delete it from R2 only once the
   new one has its own good base backups (check `first_recoverability_point`).

## Procedure B: point-in-time recovery into a separate cluster

Use this for bad data, and as a restore drill. It leaves the live cluster
alone: you restore into a throwaway cluster, copy out what you need, and delete
it.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restore
  namespace: database
spec:
  instances: 1
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ClusterImageCatalog
    major: 18
    name: postgresql-standard-trixie
  postgresql:
    parameters:
      max_connections: "600" # must be >= the source's, or recovery refuses to start
    extensions:
      - name: vchord
        image:
          reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1
        dynamic_library_path:
          - /usr/lib/postgresql/18/lib
        extension_control_path:
          - /usr/share/postgresql/18/
    shared_preload_libraries:
      - vchord.so
  storage:
    size: 25Gi
    storageClass: miroir-local
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-10-27 12:00:00+00" # just before the damage; omit for latest
  externalClusters:
    - name: origin
      plugin:
        isWALArchiver: true
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cfr2
          serverName: postgres18 # the live archive (the current serverName in cluster.yaml)
```

Two things that matter:

- **There is no `plugins` section on purpose.** The restore cluster must not
  archive WAL, or it would write into the real archive.
- **Keep the `vchord` extension block.** Without it, databases that use it
  (Immich) restore but fail when queried.

Apply it, then:

```bash
kubectl cnpg status postgres-restore -n database
kubectl cnpg psql postgres-restore -n database -- -d <database> -c "SELECT count(*) FROM <table>;"
```

To pull data back into production, use `pg_dump` from `postgres-restore` and
load it into `postgres-rw`. When done:

```bash
kubectl delete cluster postgres-restore -n database
```

**As a drill:** note the time between applying the manifest and
`Cluster in healthy state`. That is your measured RTO for the data size at that
moment. Do it once now and again whenever the data size changes a lot, and
write the number here.

## Known sharp edge

The `bootstrap.recovery` block in `cluster.yaml` is a record of the Miroir
migration (restore of the 2026-09-08 backup from `postgres18-v1`). It only has an
effect when a `Cluster` is *created*. If the `Cluster` object were deleted and
Flux recreated it from the file as it stands, the new cluster would try to
restore that old backup and archive into a non-empty `postgres18`. The plugin's
empty-archive check should stop it before it does damage, but this has not been
tested, so don't rely on it: follow Procedure A step 4 first.

## What this does not cover

- **etcd:** snapshots every 6 hours, age-encrypted, in Garage under
  `etcd-backup/` in the `kopiur` bucket (see
  [`talos-backup`](../kubernetes/apps/system-upgrade/talos-backup/)). A restore
  drill for those uses `talosctl bootstrap --recover-from` on a throwaway
  cluster.
- **Kritika's database** (`kritika-postgres`): a separate cluster, no
  barman-cloud archive.
- **Application volumes:** Kopiur's snapshots.
