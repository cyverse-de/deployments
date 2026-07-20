---
type: Runbook
title: VICE Troubleshooting
description: Diagnosing stuck or broken VICE interactive apps — loading-page stalls, scheduling and image pull failures, readiness problems, and orphaned resources.
resource: /docs/vice-troubleshooting.md
tags: [vice, interactive-apps, troubleshooting, app-exposer, vice-operator, kubernetes]
timestamp: 2026-07-20T00:00:00Z
---

This runbook covers diagnosing and resolving problems with VICE (Visual Interactive Computing
Environment) interactive apps — the kind that launch as long-running Kubernetes Deployments
and are accessed through a browser.

For batch (non-interactive) analysis problems, see
[Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md).

## Overview: the VICE launch pipeline

```
User clicks "Launch" in the DE
        │
        ▼
     Terrain           ← validates request, calls apps service
        │
        ▼
      apps             ← creates analysis record, calls app-exposer
        │
        ▼
   app-exposer         ← validates quota, builds spec, schedules to an operator
        │
        ▼
  vice-operator        ← builds k8s resources, creates Deployment/Service/HTTPRoute
        │
        ▼
   Kubernetes          ← schedules pod onto a node
        │
        ▼
   Image pulled        ← node downloads container image
        │
        ▼
  Container starts     ← app process starts, readiness probe checked
        │
        ▼
  vice-operator        ← detects readiness, swaps HTTPRoute from loading page to app
        │
        ▼
   vice-proxy          ← authenticates user, proxies browser connection to the app
        │
        ▼
  User sees app        ← browser connects through gateway → vice-proxy → app container
```

The DE UI shows a loading page (served by vice-operator) until the container passes
its readiness probe and vice-operator swaps the route to the actual app. If anything
in this chain stalls, the user sees the loading page indefinitely (or an error).

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf   # or qa.conf
export NS=prod                        # DE services namespace
export VICE_NS=vice-apps              # VICE app pods namespace
export DBMS_HOST=<dbms-host>          # from dbms_host in the inventory
```

## 1. App stuck on loading page

This is the most common VICE complaint. Work through the stages below in order.

### Stage 1 — Find the pod

```bash
# Find by analysis-id (the UUID shown in the DE Analyses panel — most reliable)
kubectl -n $VICE_NS get pods -l analysis-id=<analysis-uuid>

# Find by username (lists all pods for that user)
kubectl -n $VICE_NS get pods -l username=<username>

# List all VICE pods with their status
kubectl -n $VICE_NS get pods -o wide
```

Pod labels set by app-exposer include: `username`, `external-id`, `analysis-id`, `app-name`,
`app-id`, `analysis-name`, `app-type`, `user-id`, `subdomain`.

> **Note on pod names:** Pod names are currently the `external-id` (execution ID), not the
> `analysis-id` shown in the DE UI. These are different UUIDs. When you have an analysis ID
> from the UI or the database, use the `-l analysis-id=<uuid>` label selector rather than
> trying to match the pod name directly.

### Stage 2 — Check pod status

```bash
kubectl -n $VICE_NS describe pod <pod-name>
```

Key things to look for in the `describe` output:

**"Pending" with no node assigned** → scheduling problem; see §2 below.

**"Pending" with Events showing image pull errors:**
```
Failed to pull image "...": ... 404 Not Found
```
→ Image does not exist in the registry; see §3 below.

**"Pending" with Events showing `ErrImagePull` or `ImagePullBackOff`:**
→ Registry credentials problem or network issue; see §3 below.

**"Running" but readiness probe failing:**
```
Readiness probe failed: ...
```
→ The container started but the app inside is not ready; see §4 below.

**"CrashLoopBackOff":**
→ The container exits repeatedly; see §5 below.

## 2. Pod stuck in "Pending" — scheduling issues

```bash
kubectl -n $VICE_NS describe pod <pod-name> | grep -A20 "Events:"
```

### Not enough resources

```
0/N nodes are available: N Insufficient cpu, N Insufficient memory.
```

Check available cluster capacity:

```bash
kubectl describe nodes | grep -A5 "Allocated resources"
```

On bare-metal clusters, there may genuinely not be enough capacity. On EKS with Karpenter,
this should trigger a new node; if it doesn't, check the Karpenter logs:

```bash
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --since=10m | grep -i "error\|<pod-name>"
```

### Node affinity / taint mismatch

VICE pods require nodes with an `analysis=true` label (and tolerate the `analysis:NoSchedule`
taint). If those nodes don't exist or are all full:

```bash
# Check analysis nodes
kubectl get nodes -l analysis=true

# Check taints on those nodes
kubectl describe node <analysis-node> | grep Taint
```

### GPU analysis can't find a GPU node

```bash
kubectl -n $VICE_NS describe pod <pod-name> | grep -A5 "gpu\|nvidia\|GPU"
```

Check whether the required GPU node pool has any available nodes and that the GPU labels match
(see `vice_operator_gpu_model_mappings` in the inventory for EKS label translation).
See [GPU Workers](/infrastructure/gpu-workers.md) for GPU node setup.

## 3. Image pull failures

### Verify the image reference

```bash
kubectl -n $VICE_NS get pod <pod-name> -o jsonpath='{.spec.containers[0].image}'
```

Try to pull the image manually from a node or a scratch pod to verify it exists and that
credentials work:

```bash
# Verify the image exists and is pullable
docker pull <image-ref>
```

### Check the image pull secret

VICE pods use a secret named `vice-image-pull-secret` in the `vice-apps` namespace. If it has
expired or is misconfigured:

```bash
kubectl -n $VICE_NS get secret vice-image-pull-secret
# Decode and inspect the credentials
kubectl -n $VICE_NS get secret vice-image-pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
```

To recreate it:

```bash
kubectl -n $VICE_NS delete secret vice-image-pull-secret
kubectl -n $VICE_NS create secret docker-registry vice-image-pull-secret \
  --docker-server=harbor.cyverse.org \
  --docker-username=<robot-account> \
  --docker-password=<token>
```

See [Harbor](/infrastructure/harbor.md) for registry administration.

### New app with a private or custom registry

If a user published an app pointing at an image in a private registry that the cluster has no
credentials for, the pull will fail. Verify the image registry and whether it requires
authentication. If it is a public image that was misspelled or deleted, the user must fix the
tool definition.

## 4. Container running but app not ready

The container started but the readiness probe is failing. This means the process inside the
container is running but not listening on the expected port, or is taking longer than expected
to initialize.

```bash
# Check current probe status
kubectl -n $VICE_NS describe pod <pod-name> | grep -A5 "Readiness"

# Get the app's logs
kubectl -n $VICE_NS logs <pod-name>
kubectl -n $VICE_NS logs <pod-name> --previous   # logs from the last restart, if any
```

Common causes:
- **App startup is slow**: Some tools (RStudio, large Jupyter kernels) take a minute or two.
  The default readiness probe has a failure threshold; if the app consistently takes longer,
  the tool definition's probe settings may need adjustment.
- **Port mismatch**: The tool was published with the wrong container port. Check the app-exposer
  logs:
  ```bash
  kubectl -n $NS logs -l de-app=app-exposer --since=30m | grep -i "<uuid>\|error\|port"
  ```
- **App crashed silently on startup**: Check `kubectl logs` for Python/R/startup errors.

## 5. CrashLoopBackOff

The container starts and immediately exits. This is almost always an issue with the container
image or its entrypoint, not with the DE infrastructure.

```bash
# Get logs from the current (crashed) attempt
kubectl -n $VICE_NS logs <pod-name>

# Get logs from the previous attempt
kubectl -n $VICE_NS logs <pod-name> --previous

# Check exit code
kubectl -n $VICE_NS describe pod <pod-name> | grep "Exit Code"
```

If the exit code is `OOMKilled` (exit 137), the container hit its memory limit. The tool
definition may need a higher memory request/limit.

If the app is a new tool from a user, the most likely cause is a broken `CMD`/entrypoint in
their Dockerfile. This is not something the DE team can fix — the user needs to fix their image.

## 6. User can't connect after the app is "Running"

The loading page disappears, the app shows as Running in the DE, but the user's browser
shows an error or can't connect.

### Check vice-proxy

`vice-proxy` is the authenticating sidecar that proxies browser traffic to the app container.

```bash
kubectl -n $VICE_NS logs <pod-name> -c vice-proxy
```

Look for:
- Authentication errors (Keycloak token validation failures)
- `connection refused` to the app container — the app started but is not listening on the
  expected port (same as §4 above, but the readiness probe may have passed prematurely)

### Check Traefik / the Gateway

```bash
kubectl -n traefik logs -l app.kubernetes.io/name=traefik --since=10m | grep -i "<subdomain>\|error"
```

Verify the `HTTPRoute` was created for this analysis:

```bash
kubectl -n $VICE_NS get httproute -l external-id=<uuid>
```

If the HTTPRoute doesn't exist, app-exposer failed to create it. Check app-exposer logs.

### TLS certificate for the VICE domain

If the wildcard cert for `*.cyverse.run` (or equivalent) has expired, all VICE apps will show
a TLS error. Check:

```bash
kubectl -n $NS get certificate | grep vice
kubectl -n $NS describe certificate <vice-cert-name>
```

See [Certificate Management](/playbooks/certificate-management.md) for renewal procedures.

## 7. Forcibly terminating a stuck VICE app

If a user can't terminate their app through the UI, or if the app is consuming excessive
resources, you can terminate it directly.

### Via the DE admin panel

Navigate to the VICE admin page in Sonora (`/admin/vice`). From there you can terminate any
running VICE analysis without touching `kubectl`.

### Via kubectl

```bash
# Find the pod by analysis-id
kubectl -n $VICE_NS get pods -l analysis-id=<analysis-uuid>

# Delete the deployment — app-exposer will clean up the rest
# (The deployment name matches the external-id / pod name, not the analysis-id;
#  get it from the pod's ownerReferences or from the pod name itself)
kubectl -n $VICE_NS get pods -l analysis-id=<analysis-uuid> \
  -o jsonpath='{.items[0].metadata.ownerReferences[0].name}'
kubectl -n $VICE_NS delete deployment <deployment-name>

# Update the analysis status in the database if it remains "Running"
psql -h $DBMS_HOST -U de -d de -c \
  "UPDATE jobs SET status='Canceled', end_date=NOW() WHERE id='<analysis-uuid>' AND status='Running';"
```

> **Note:** Deleting the Deployment does not automatically trigger output file transfer. If
> the user had unsaved work in the container, it is lost. Warn the user before terminating.

## 8. Cleaning up orphaned VICE resources

After a cluster failure, reboot, or manual pod deletion, VICE resources (Deployments, Services,
HTTPRoutes) may linger in `vice-apps` even though the analysis is already marked done in the
DB.

```bash
# List all deployments in vice-apps
kubectl -n $VICE_NS get deployments

# For each deployment, check whether its analysis-id is still Running in the DB.
# Note: the deployment name is the external-id; get the analysis-id from its pod label.
ANALYSIS_ID=$(kubectl -n $VICE_NS get pods -l \
  "external-id=$(kubectl -n $VICE_NS get deployment <name> \
    -o jsonpath='{.spec.selector.matchLabels.external-id}')" \
  -o jsonpath='{.items[0].metadata.labels.analysis-id}' 2>/dev/null)

psql -h $DBMS_HOST -U de -d de -t -A -c "SELECT status FROM jobs WHERE id='$ANALYSIS_ID';"

# If status is not 'Running', delete the deployment
kubectl -n $VICE_NS delete deployment <name>
```

vice-operator's reconciliation loop should catch most of these, but on a fresh cluster restart
it may take a few minutes.

## 9. New app doesn't work — user-published tool

When a user publishes a new VICE app and it doesn't work, the DE infrastructure is usually
fine and the problem is in the user's image. Before spending time on the cluster side:

1. **Ask for the full image reference** (`harbor.cyverse.org/...` or a public registry).
2. **Try to run it locally**: `docker run -p 8888:8888 <image>` — if it fails locally, it's
   the image.
3. **Check the exposed port** in the tool definition matches what the app listens on.
4. **Check the entrypoint**: some images need a specific `CMD` to start the server.
5. **Check the readiness URL**: app-exposer polls `<app-url>/` by default; some apps use a
   different health path.

If the app works locally but not in the DE, check:
- Does the image require environment variables that aren't set in the tool definition?
- Does the container run as root, and does the cluster enforce Pod Security Admission rules
  that block privileged containers?
- Does the app need a GPU and was the tool definition configured for GPU?

# Citations

[1] `docs/vice-troubleshooting.md` — source document for this page.
