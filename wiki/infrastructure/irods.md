---
type: Service
title: iRODS and Data Store
description: How the DE connects to iRODS — verifying connectivity, data-info failures, service account rotation, the iRODS CSI driver, and file transfer troubleshooting.
resource: /docs/irods.md
tags: [irods, data-store, csi-driver, gocmd, vice, file-transfers]
timestamp: 2026-07-20T00:00:00Z
---

iRODS is the data store for all user files. This page covers the DE's connection to iRODS,
how to verify it is working, how to diagnose `data-info` connectivity failures, the iRODS
CSI driver, the service account, and file transfer troubleshooting.

## Overview

The DE connects to iRODS in several ways:

| Component | How it connects | Purpose |
|---|---|---|
| [data-info](/services/data-info.md) | Jargon (iRODS Java API, direct TCP) | File browser, metadata, sharing |
| `gocmd` (batch workflows) | Go iRODS client (direct TCP) | Batch job input download and output upload |
| `vice-file-transfers` | Jargon (porklock JAR) | VICE interactive app file sync |
| iRODS CSI driver | irodsfuse | Mounts user directories into VICE pods |
| [info-typer](/services/info-typer.md) / [dewey](/services/dewey.md) | AMQP events from iRODS | File type detection, indexing |

The DE authenticates to iRODS as a single service account (configured via `irods_user`,
`irods_password`, `irods_zone` in the inventory). This service account must have the
appropriate permissions in iRODS to act on behalf of users.

## The iRODS CSI driver

The CSI driver mounts user home directories into VICE pods over irodsfuse. It is installed
by the `kubernetes_irods_csi_driver` role, which runs in `kubernetes.yml` (and
`vice-operator-eks.yml`) under the `irods-csi-driver` tag:

```bash
ansible-playbook -i /path/to/inventory --tags=irods-csi-driver kubernetes.yml
```

The role (see `ansible/roles/kubernetes_irods_csi_driver/tasks/main.yml`):

- Installs the `irods-csi-driver` Helm chart from
  https://cyverse.github.io/irods-csi-driver-helm/ at `irods_csi_driver_version` into the
  `irods_csi_driver_namespace` namespace. Connection settings come from the
  `irods_csi_driver_*` inventory variables (client, host, port, zone, user, password,
  `retainData`, `enforceProxyAccess`, mount path whitelist, pool server endpoint, cache
  settings, `kubeletDir`), which land in a Helm-managed Secret mounted into the driver
  pods.
- Pins both the controller Deployment and node DaemonSet to `amd64` Linux nodes, because
  `cyverse/irods-csi-driver` only publishes amd64 images (arm64 nodes fail with an exec
  format error).
- Restarts the controller and node DaemonSet (via a `restartedAt` annotation) whenever the
  Helm release changed — Helm updates the Secret in place but the pod templates don't
  change, so without the restart the driver keeps reading stale credentials.
- Defines the `irods-sc` StorageClass with provisioner `irods.csi.cyverse.org`.

`ansible/irods_csi_driver_values.yml` is a standalone Helm values file with the QA
settings (host, zone, pool server endpoint, cache timeouts, k0s kubelet dir) for manual
`helm` runs outside of Ansible.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf
export NS=prod
export VICE_NS=vice-apps
export CSI_NS=irods-csi-driver    # iRODS CSI driver namespace (irods_csi_driver_namespace)
export IRODS_HOST=<irods_host from inventory>
```

## 1. Verify iRODS connectivity from the cluster

### Quick connectivity check from data-info

```bash
# data-info's /data-info/admin/filesystem/entry proxies to iRODS
kubectl -n $NS logs -l de-app=data-info --since=5m | grep -i "error\|irods\|jargon"
```

If `data-info` logs show `CONNECTION_REFUSED` or `COMMUNICATION_PROTOCOL_ERROR`, the iRODS
server is not reachable from the cluster network.

### Test TCP connectivity from inside the cluster

```bash
# Run a one-shot pod that checks TCP connectivity to iRODS port 1247
kubectl -n $NS run irods-check --rm -it --restart=Never --image=alpine -- \
  sh -c "nc -zv $IRODS_HOST 1247 && echo OK || echo FAILED"
```

### Check data-info health endpoint

```bash
kubectl -n $NS port-forward svc/data-info 60000:60000 &
curl -s http://localhost:60000/
```

A working response is a JSON or text health status. An error connecting usually indicates
data-info is not running.

## 2. data-info connectivity failures

`data-info` is the primary gateway for all iRODS file operations in the DE. When it fails,
users cannot browse files, upload/download, or share data.

### Check data-info logs

```bash
kubectl -n $NS logs -l de-app=data-info --since=30m --tail=200 | grep -i "error\|exception\|irods\|jargon"
```

Common error patterns and causes:

| Log message | Likely cause |
|---|---|
| `CAT_INVALID_AUTHENTICATION` | iRODS service account password is wrong or has been changed |
| `CONNECTION_REFUSED` or `COMM_FAILURE` | iRODS server is down or the host/port is wrong |
| `CAT_INVALID_USER` | The service account (`irods_user`) doesn't exist in iRODS |
| `USER_FILE_DOES_NOT_EXIST` | Normal — user navigated to a path that doesn't exist |
| `CATALOG_ALREADY_HAS_ITEM_BY_THAT_NAME` | Normal — user tried to create something that already exists |

### Restart data-info

If data-info is stuck after an iRODS hiccup:

```bash
kubectl -n $NS rollout restart deployment/data-info
kubectl -n $NS rollout status deployment/data-info
```

## 3. iRODS service account password rotation

The service account password is stored in `irods_password` in the private inventory and in
the `configs` Kubernetes Secret.

### Step 1 — Change the password in iRODS

Use iCommands or the iRODS admin console:

```bash
iadmin moduser <irods_user> password <new-password>
```

### Step 2 — Update the inventory

Update `irods_password` in the private inventory repository.

### Step 3 — Push new config and restart

```bash
ansible-playbook -i /path/to/inventory --tags=configure-services kubernetes.yml

kubectl -n $NS rollout restart deployment/data-info
# Batch workflows (gocmd) and VICE file transfers pick up credentials from
# the configs Secret at pod start, so no restart needed — new jobs will use
# the updated credentials automatically.
```

### Step 4 — Update the iRODS CSI driver credentials

The CSI driver uses a Helm-managed Secret (deployed by the `kubernetes_irods_csi_driver`
role into the `irods-csi-driver` namespace). The correct way to update it is to change the
inventory and re-run the role:

```bash
# After updating irods_password (and optionally irods_user) in the inventory:
ansible-playbook -i /path/to/inventory --tags=irods-csi-driver kubernetes.yml
```

The role will update the Helm release values (which updates the Secret) and automatically
restart the controller Deployment and node DaemonSet if anything changed.

If you need to verify the driver picked up the new credentials:

```bash
kubectl -n $CSI_NS rollout status deployment/irods-csi-driver-controller
kubectl -n $CSI_NS rollout status daemonset/irods-csi-driver-node
```

## 4. iRODS CSI driver health check

If the CSI driver is unhealthy, users' files are not visible inside their running VICE
apps.

### Check CSI driver pods

```bash
kubectl -n $CSI_NS get pods
```

There should be:
- One `irods-csi-driver-controller-*` pod (Deployment)
- One `irods-csi-driver-node-*` pod per node (DaemonSet)

### Check CSI driver logs

```bash
kubectl -n $CSI_NS logs -l app.kubernetes.io/name=irods-csi-driver --since=30m | grep -i "error\|mount\|failed"
```

### Verify a mount from inside a VICE pod

```bash
# Get a VICE pod that should have an iRODS mount
kubectl -n $VICE_NS get pods -l username=<username>

# Check if the iRODS mount is present (mount path is /data-store/<zone>/home/<username>)
kubectl -n $VICE_NS exec <pod-name> -- ls /data-store
```

If the listing fails or the directory appears empty when it shouldn't, the CSI driver
mount failed. Check the pod's volume status:

```bash
kubectl -n $VICE_NS describe pod <pod-name> | grep -A10 "Volumes:"
kubectl -n $VICE_NS describe pod <pod-name> | grep -A5 "Mounts:"
```

## 5. Batch job file transfer issues (gocmd)

Batch Argo Workflows use `gocmd` (a Go-based iRODS client) in dedicated `download-files`
and `upload-files` steps to transfer inputs from and outputs to iRODS. If the upload step
fails, job results are lost. See
[Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md) §3 for
diagnosing when outputs don't appear after a job completes.

Common iRODS errors in gocmd output:

```
CAT_INVALID_AUTHENTICATION    → service account password is wrong
USER_FILE_DOES_NOT_EXIST      → output path doesn't exist in iRODS
SYS_COPY_LEN_ERR              → file was modified during transfer (rare)
```

gocmd runs as a step in the Argo Workflow (not a long-running Deployment). Find its logs:

```bash
# List pods from a specific workflow and find the upload/download step
kubectl -n $NS get pods | grep <analysis-uuid>
kubectl -n $NS logs <upload-files-pod-name>
```

## 6. VICE interactive file transfers (vice-file-transfers)

`vice-file-transfers` is a sidecar that runs inside VICE pods and handles explicit file
uploads/downloads triggered from the DE UI ("Save Outputs" button). It is separate from
the CSI driver mount.

```bash
kubectl -n $VICE_NS logs <vice-pod-name> -c vice-file-transfers
```

Common issues:
- Transfer appears to hang: check if `vice-file-transfers` is running (`kubectl get pods`
  and check all containers in the pod with `kubectl describe pod`)
- `CAT_INVALID_AUTHENTICATION`: service account credentials are wrong (same root cause as §3)

## 7. Files written outside the persisted directory

A common support case: a user's work completed successfully, but their output files are
not in the data store. The root cause is the same in both batch and VICE contexts — files
were written to a container-local path that is not backed by persistent storage.

### Batch analyses

Batch workflows use a generic PVC volume as the working directory. The `upload-files` step
transfers only files from this volume back to iRODS via `gocmd`. If the tool writes to
`/tmp` or any other path outside the working volume, those files are not transferred.

This is typically a **tool/app authoring issue** — the tool definition specifies a working
directory, and the tool's script must write output there.

**Diagnosis:** Check the upload-files log for the job (§5 above). If the upload step ran
successfully but transferred zero or fewer files than expected, the output was written to
the wrong location.

**Resolution:** The tool author needs to update the tool to write output to the configured
working directory (visible in the tool definition and in the "Input/Output" section of the
app launch form).

### VICE interactive apps

VICE apps have the user's data store mounted via the iRODS CSI driver at
`/data-store/<zone>/home/<username>` (e.g., `/data-store/iplant/home/jsmith`). Files
written anywhere else in the container exist only for the lifetime of the pod — they are
lost when the session ends.

This is typically **user error** — the user saved files to a local path (container home
directory, `/tmp`, desktop, etc.) rather than the mounted data store path.

**Diagnosis:** If the user reports missing files after a VICE session ended, ask where
they saved their work. If it was not under the `/data-store/` mount, the files are gone.

**Resolution:** Inform the user that only files written under `/data-store/` persist after
the session ends. There is no recovery path for files written elsewhere once the pod is
deleted.

> **Note:** If the CSI driver mount itself failed (empty `/data-store/` directory), that
> is a different problem — see §4 above for CSI driver health checks.

# Citations

[1] `docs/irods.md` — source document for this page.
[2] `ansible/roles/kubernetes_irods_csi_driver/tasks/main.yml` — role that installs the iRODS CSI driver Helm chart, restart-on-change logic, and the `irods-sc` StorageClass.
[3] `ansible/irods_csi_driver_values.yml` — standalone Helm values file with QA settings for manual chart installs.
[4] `ansible/kubernetes.yml` — runs the CSI driver role under the `irods-csi-driver` tag.
