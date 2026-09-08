# Migrating CNPG off openebs-hostpath onto Miroir

This is the runbook for moving the `postgres` CloudNativePG cluster from
`openebs-hostpath` to Miroir's `miroir-local` StorageClass (loopfile
backend, no dedicated disk).

You're keeping the cluster name (`postgres`) and accepting downtime, so this
is a **delete-and-recover-in-place**, not a parallel-cluster cutover: take a
final backup, delete the `Cluster` object (and its `openebs-hostpath` PVCs),
then let CNPG recreate `postgres` from scratch via the barman-cloud plugin,
recovering from that backup onto `miroir-local`. Nothing about the Pooler,
Gatus check, or ScheduledBackup needs to change - they all reference the
cluster by the name `postgres`, which never changes.

The actual data never lives only on the local PVC during this: WAL and base
backups are already in Cloudflare R2 via the `cfr2` ObjectStore, so deleting
the local PVCs doesn't touch your only copy.

## 0. Prerequisites

- The `migrate-openebs-to-miroir` branch (Miroir chart, `MiroirNodeGroup`,
  `miroir-local` StorageClass) is merged and Flux has reconciled it.
- **Before that first reconcile**, create and label the namespace by hand -
  Talos enforces the baseline Pod Security Standard by default, which
  silently rejects the privileged `miroir-agent` DaemonSet:

    ```bash
    kubectl create namespace miroir-system
    kubectl label namespace miroir-system pod-security.kubernetes.io/enforce=privileged
    ```

    (This is presumably how `openebs-system` and `rook-ceph` already got their
    exemption too - neither namespace.yaml carries the label in git.)

- This branch also repoints [`cloudnative-pg/ks.yaml`](../kubernetes/apps/database/cloudnative-pg/ks.yaml)'s
  `cloudnative-pg-cluster` Kustomization from `dependsOn: openebs` to
  `dependsOn: miroir-config` - the cluster's Flux Kustomization won't
  reconcile until the StorageClass exists. Make sure this lands _before_ you
  delete the old cluster, or Flux won't be able to recreate it.

## 1. Validate Miroir on its own, before touching Postgres

Don't let CNPG be the first workload to touch the new storage class.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: miroir-smoke-test
  namespace: default
spec:
  storageClassName: miroir-local
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: miroir-smoke-test
  namespace: default
spec:
  containers:
    - name: writer
      image: busybox
      command: ["sh", "-c", "echo hello > /data/hello && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: miroir-smoke-test
EOF

kubectl wait --for=condition=Ready pod/miroir-smoke-test -n default --timeout=60s
kubectl get miroirnodes
kubectl exec miroir-smoke-test -- cat /data/hello
```

Confirm `kubectl get miroirnodes` shows all three control-plane nodes with
the `default` pool healthy, then delete the smoke-test Pod/PVC:

```bash
kubectl delete pod miroir-smoke-test -n default
kubectl delete pvc miroir-smoke-test -n default
```

## 2. Prepare CNPG

1. **Confirm backups and WAL archiving are healthy right now**, before you
   start:

    ```bash
    kubectl cnpg status postgres -n database
    kubectl get backups -n database
    ```

    Look for continuous archiving with no pending WALs and a recent
    `Completed` backup.

2. **Take a fresh on-demand backup** as your actual recovery point - this is
   what the rebuilt cluster restores from, so don't skip it:

    ```bash
    kubectl apply -f - <<'EOF'
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: postgres-pre-miroir-migration
      namespace: database
    spec:
      cluster:
        name: postgres
      target: primary
      method: plugin
      pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
    EOF

    kubectl wait --for=jsonpath='{.status.phase}'=completed \
      backup/postgres-pre-miroir-migration -n database --timeout=10m
    ```

    Without `target: primary`, CNPG can dispatch the backup to a standby
    instead - hit this during testing: `pg_backup_start` got canceled with
    `canceling statement due to conflict with recovery` (a hot-standby
    recovery conflict, not a storage/credentials problem). Forcing `primary`
    avoids that class of failure entirely.

3. Note the live cluster's current archive name - it's `postgres18-v1` in
   [`cluster.yaml`](../kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml).
   The rebuilt cluster needs its own, unused archive path (barman-cloud
   won't let a new system identifier share a `serverName` with the old one),
   so this runbook bumps it to `postgres18-v2`.

## 3. Take the cluster down

1. Optional but recommended - stop Flux from fighting you mid-teardown:

    ```bash
    flux suspend kustomization cloudnative-pg-cluster -n flux-system
    ```

2. Delete the `Cluster`. This tears down the instances; CNPG owns the
   per-instance PVCs, so they should cascade-delete with it, but verify:

    ```bash
    kubectl delete cluster postgres -n database

    kubectl get pvc -n database -l cnpg.io/cluster=postgres
    # if anything is still listed:
    kubectl delete pvc -n database -l cnpg.io/cluster=postgres
    ```

    The `Pooler` (`pgbouncer-rw`) and the Gatus check will start failing here
    - expected, that's the downtime window. Nothing needs editing on either;
      they come back on their own once `postgres` exists again.

## 4. Rebuild on Miroir storage

Edit [`cluster.yaml`](../kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml)
in place - keep `metadata.name: postgres` and everything else (affinity,
`imageCatalogRef`, `postgresql.extensions`, `superuserSecret`, etc.)
unchanged:

```diff
   storage:
     size: 25Gi
-    storageClass: openebs-hostpath
+    storageClass: miroir-local
   plugins:
     - enabled: true
       isWALArchiver: true
       name: barman-cloud.cloudnative-pg.io
       parameters: &barmanParameters
         barmanObjectName: cfr2
-        serverName: postgres18-v1
+        serverName: postgres18-v2
   bootstrap:
     recovery:
-      source: postgres18
+      source: postgres18-v1
   externalClusters:
-    - name: postgres18
+    - name: postgres18-v1
       plugin:
         enabled: true
         isWALArchiver: true
         name: barman-cloud.cloudnative-pg.io
         parameters:
           barmanObjectName: cfr2
-          serverName: postgres18
+          serverName: postgres18-v1
```

This is the same shape your `postgres18` -> `postgres` migration already
used - just shifted one version forward, recovering from what was, until
Step 3, the live archive.

Commit, then resume Flux if you suspended it:

```bash
flux resume kustomization cloudnative-pg-cluster -n flux-system
```

Watch it come back:

```bash
kubectl cnpg status postgres -n database
kubectl get pods -n database -l cnpg.io/cluster=postgres
```

Wait for `Cluster in healthy state` with all 3 instances streaming - this is
the end of the downtime window.

## 5. Validate

```bash
kubectl cnpg psql postgres -n database -- -c "\dx"        # vchord extension present
kubectl cnpg psql postgres -n database -- -c "SELECT count(*) FROM <a table you know>;"
```

Compare against what you'd expect as of the Step 2 backup. Also confirm the
`Pooler` and Gatus check have recovered on their own:

```bash
kubectl get pooler pgbouncer-rw -n database
```

## 6. Cleanup

Once you're confident the rebuilt cluster is solid:

1. Confirm `kubectl get backups -n database` shows successful backups
   landing on the new `postgres18-v2` archive path.
2. Remove [`kubernetes/apps/openebs-system/`](../kubernetes/apps/openebs-system/)
   entirely - nothing references `openebs-hostpath` anymore.

## Rollback

If the rebuilt cluster comes up unhealthy or recovery fails: the Step 2
backup and every WAL segment before it are still sitting in `cfr2` under
`postgres18-v1`, untouched by any of this. Re-run Step 4 with
`storageClass: openebs-hostpath` instead of `miroir-local` (keep the
`postgres18-v2` naming bump either way, since `postgres18-v1` is still what
you're recovering _from_) to get back to exactly where you started, on the
old storage.
