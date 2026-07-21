---
type: Service
title: Longhorn
description: The opt-in longhorn role that installs Longhorn replicated block storage via Helm — default StorageClass, replica sizing, and backup-target handling. Superseded by OpenEBS.
resource: /ansible/roles/longhorn
tags: [longhorn, storage, helm, kubernetes.yml]
timestamp: 2026-07-21T00:00:00Z
---

Longhorn provides replicated block storage for the cluster. The `longhorn` role installs
the upstream Helm chart (`longhorn_version`, currently 1.12.0) into `longhorn_namespace`
(default `longhorn-system`). It is opt-in — `longhorn_enabled` defaults to `false` — and
runs in `kubernetes.yml` under the `longhorn` tag:

```bash
ansible-playbook -i <inventory> --tags longhorn -e longhorn_enabled=true kubernetes.yml
```

It is ordered before [Harbor](/infrastructure/harbor.md) in `kubernetes.yml` because
Harbor's PVCs use the `longhorn` StorageClass (`harbor_storage_class`); the
[OpenSearch](/infrastructure/opensearch.md) PVC uses it by default as well.

## Configuration

- The chart auto-creates a StorageClass named `longhorn` and makes it the cluster
  default, since Longhorn is the primary CSI driver installed for general-purpose block
  storage (the [iRODS](/infrastructure/irods.md) CSI driver is only for the data store).
- Replica count (`longhorn_replica_count`) defaults to the smaller of the `k8s_workers`
  group size and 3, applied to both the StorageClass and `defaultSettings`, so it adapts
  to clusters with fewer than three nodes.
- Data lives at `longhorn_data_path` (default `/var/lib/longhorn`) on each node; the
  StorageClass reclaim policy is `longhorn_reclaim_policy` (default `Retain`).
- Tolerations: `longhorn_tolerations` defaults to tolerating the `vice=only:NoSchedule`
  and `analysis=only:NoSchedule` taints (the same pair the
  [OpenEBS](/infrastructure/openebs.md) role patches onto its workloads), because the
  node CSI plugin must run on every node where pods mount Longhorn volumes — without it,
  attach fails with `CSINode <node> does not contain driver driver.longhorn.io`. The list
  feeds two chart values: `global.tolerations` for the user-deployed workloads (manager,
  UI, driver deployer) and `defaultSettings.taintToleration` — derived as a
  semicolon-separated `key=value:effect` string, so entries must use the `Equal`
  operator — for the system-managed ones (CSI plugin, instance managers, engine images).
- Backups: the `defaultBackupStore` values (`longhorn_backup_target`,
  `longhorn_backup_target_credential_secret`, `longhorn_backupstore_poll_interval`) are
  only passed to the chart when `longhorn_backup_target` is non-empty. The chart omits
  null values from its `longhorn-default-resource` ConfigMap but writes empty keys for
  `""`, so sending empty strings would churn that ConfigMap on every existing install for
  no benefit. Longhorn creates its `default` BackupTarget with an empty URL either way —
  and that object must never be deleted while longhorn-manager is running (see
  [Longhorn Teardown](/playbooks/longhorn-teardown.md)).

## Status

[OpenEBS](/infrastructure/openebs.md) replaced Longhorn as the cluster storage layer.
The role remains for existing installs; to remove a previous Longhorn install, follow
[Longhorn Teardown](/playbooks/longhorn-teardown.md) — it is an all-or-nothing procedure.

# Citations

[1] `ansible/roles/longhorn/tasks/main.yml` — Helm install, StorageClass/replica values, backup-store conditional.
[2] `ansible/roles/common/defaults/main.yml` — `longhorn_*` variable defaults, including `longhorn_enabled: false`.
[3] `ansible/kubernetes.yml` — the `longhorn` tag and ordering ahead of Harbor.
