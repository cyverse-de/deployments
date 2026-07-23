---
type: Runbook
title: General Operations Runbook
description: Day-to-day DE cluster operations — health checks, restarts, scaling, rollbacks, config pushes, log access, and node maintenance.
resource: /docs/ops-runbook.md
tags: [operations, runbook, kubectl, deploy, rollback, logs, health]
timestamp: 2026-07-20T00:00:00Z
---

Quick reference for day-to-day DE cluster operations. For topic-specific procedures see:
- [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md)
- [VICE Troubleshooting](/playbooks/vice-troubleshooting.md)
- [Certificate Management](/playbooks/certificate-management.md)
- [Keycloak](/infrastructure/keycloak.md)
- [PostgreSQL](/infrastructure/postgresql.md)
- [iRODS](/infrastructure/irods.md)

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf   # or qa.conf
export NS=prod                        # DE services namespace
export VICE_NS=vice-apps
export DE_HOST=https://<de_hostname>  # from de_hostname in the inventory
export RABBITMQ_HOST=<rabbitmq-host>  # from rabbitmq_host in the inventory
```

> **Kubeconfig resolution:** `KUBECONFIG` alone does not guarantee which cluster Ansible will
> target. An inventory's `group_vars` can pin `kubeconfig` explicitly and silently win over
> your exported env var. Before any `ansible-playbook` or `kubectl` command that mutates a
> cluster, confirm both `KUBECONFIG` and the inventory agree on the same environment.
> **Deploying to production requires explicit confirmation — never default to it.**
> See `skills/resolving-the-kubeconfig/SKILL.md` for the full resolution procedure.

> **Working directory:** All `ansible-playbook` commands must be run from the `ansible/`
> directory of the `deployments` repo.

## 1. Health check: are all services running?

```bash
# Any non-Running, non-Completed pods in the DE namespace?
kubectl -n $NS get pods | grep -v -E 'Running|Completed'

# Count of each service's ready replicas vs desired
kubectl -n $NS get deployments

# Same for vice-apps
kubectl -n $VICE_NS get pods | grep -v -E 'Running|Completed'
```

A quick full-stack sanity check — hit the Terrain status endpoint (requires a valid
Keycloak token or admin credentials):

```bash
curl -s $DE_HOST/terrain/admin/status | jq .
```

This returns the health of iRODS, JEX, Apps, the notification agent, and
DataCite as seen by Terrain.

### Check that cert-manager and Traefik are healthy

```bash
kubectl -n cert-manager get pods
kubectl -n traefik get pods
```

### Check NATS and RabbitMQ

```bash
# NATS runs in-cluster
kubectl -n $NS get pods -l de-app=nats

# RabbitMQ runs externally — check via its management interface
# (rabbitmq_host from the inventory, management port 15672)
curl -s -u guest:guest http://$RABBITMQ_HOST:15672/api/overview | jq '{rabbitmq_version, cluster_name}'
```

See [NATS](/infrastructure/nats.md) and [RabbitMQ](/infrastructure/rabbitmq.md) for details
on either broker.

### Check Argo (batch job execution)

```bash
kubectl -n argo get pods
```

## 2. Restart a service

A rolling restart (no downtime for services with replicas > 1):

```bash
kubectl -n $NS rollout restart deployment/<service-name>
```

Watch it roll out:

```bash
kubectl -n $NS rollout status deployment/<service-name>
```

To restart all DE services at once (e.g., after a config push):

```bash
kubectl -n $NS rollout restart deployment --all
```

> **Note:** Services with `replicas: 1` (e.g., `job-status-recorder`) will have a brief
> downtime during the restart. Any AMQP messages delivered during that window are safe —
> they will be requeued by RabbitMQ and consumed when the service comes back up, assuming
> the queue's `x-dead-letter-exchange` is configured.

## 3. Scale a service

```bash
# Scale up temporarily (e.g., terrain under high load)
kubectl -n $NS scale deployment/terrain --replicas=4

# Scale back down
kubectl -n $NS scale deployment/terrain --replicas=2
```

Note: scaling changes made with `kubectl scale` are not persisted to the deployment
manifests. The next `deploy_it.yml` or `deploy-all-services` run will reset the replicas
to whatever is in the manifest. To make the change permanent, update the `replicas` field
in the service's `k8s/*.yml` in the `deployments` repo.

## 4. Roll back a bad deployment

If a freshly deployed service is broken and you need to revert to the previous image:

### Option A — Kubernetes rollback (fastest)

```bash
# Check rollout history
kubectl -n $NS rollout history deployment/<service-name>

# Roll back to the previous version
kubectl -n $NS rollout undo deployment/<service-name>

# Or roll back to a specific revision
kubectl -n $NS rollout undo deployment/<service-name> --to-revision=<N>
```

This reverts the Deployment's pod spec to the previous version but does **not** update the
build descriptor (`<service>.json`). The next deploy run will re-deploy whatever is currently
in the descriptor.

### Option B — Redeploy from a known-good descriptor

If you have the previous build descriptor (the `<service>.json` before the bad build was
recorded), restore it and redeploy:

```bash
# Restore the previous descriptor (e.g., from git)
git -C /path/to/deployments checkout HEAD~1 -- \
  ansible/roles/services/<service>/files/<service>.json

# Redeploy
ansible-playbook -i /path/to/inventory deploy_it.yml --tags <service>
```

> **`build_json_dir` caveat:** Deploys read descriptors from `build_json_dir`, which
> inventories may override to a separate `de-releases/builds` checkout (QA does this).
> If your environment uses that override, restoring the file under `roles/services/` has
> no effect on the deploy — you also need to update the descriptor in that separate
> checkout. Check `build_json_dir` in your inventory's group_vars if the rollback doesn't
> seem to take effect.

## 5. Deploy a single service update

After a new image has been built and its descriptor updated:

```bash
ansible-playbook -i /path/to/inventory deploy_it.yml --tags <service>
```

To deploy multiple services at once:

```bash
ansible-playbook -i /path/to/inventory deploy_it.yml --tags terrain,sonora,apps
```

Notes:
- **Tag order does not control deploy order.** Services run in the fixed order declared in
  `deploy_it.yml` regardless of the order you list `--tags`.
- **`load_configs=false`** skips re-rendering the service's config Secret, deploying only
  the new image. Use this to avoid overwriting hand-patched in-cluster config:
  ```bash
  ansible-playbook -i /path/to/inventory deploy_it.yml --tags <service> -e load_configs=false
  ```
- **`configure-services` must have run** in the target namespace before deploying any
  service for the first time. `deploy_it.yml` does not create the shared `configs` Secret;
  a pod in a namespace where that step hasn't run will fail to start because it can't mount
  `configs`. For a fresh namespace, run the full `kubernetes.yml --tags=configure-services`
  pass first.

See [Building and Deploying Services](/playbooks/build-and-deploy.md) for the full
build-and-deploy workflow.

## 6. Push a configuration change without rebuilding images

If you change an inventory variable that affects service configuration (e.g., a feature flag,
a URL, a credential), push the new config and restart the affected services:

```bash
# Re-render and push all service config Secrets
ansible-playbook -i /path/to/inventory --tags=configure-services kubernetes.yml

# Restart the services whose config changed
kubectl -n $NS rollout restart deployment/terrain deployment/apps
```

The `configure-services` tag only updates Kubernetes Secrets and ConfigMaps; it does not
redeploy pods. The rollout restart is needed for pods to pick up the new Secret values.

> **Warning:** The default `deploy_it.yml` run (with `load_configs=true`) will re-render
> config from the current inventory on every deploy, overwriting any in-cluster edits.
> If you need to deploy a new image without touching config (e.g., to preserve a
> hand-patched Secret), use `-e load_configs=false` as described in §5.

## 7. Check logs

```bash
# Last 100 lines from a service
kubectl -n $NS logs -l de-app=<service> --tail=100

# Follow live
kubectl -n $NS logs -l de-app=<service> -f

# Last hour, grepping for errors
kubectl -n $NS logs -l de-app=<service> --since=1h | grep -i error

# Logs from a specific pod (useful when a deployment has multiple replicas)
kubectl -n $NS logs <pod-name>

# Logs from previous container run (after a crash)
kubectl -n $NS logs <pod-name> --previous
```

## 8. Drain and cordon a node

If a node needs maintenance (OS update, hardware work):

```bash
# Prevent new pods from scheduling on the node
kubectl cordon <node-name>

# Evict existing pods (will be rescheduled on other nodes)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# After maintenance, re-enable scheduling
kubectl uncordon <node-name>
```

> **Warning:** Draining a node evicts VICE pods. Any unsaved work in running VICE apps on
> that node will be lost. If possible, notify affected users before draining.

## 9. Namespace reference

| Namespace | Contents |
|---|---|
| `prod` | All DE services (production) |
| `qa` | All DE services (QA / staging) |
| `vice-apps` | Running VICE interactive app pods (both environments share this) |
| `keycloak` | Keycloak |
| `traefik` | Traefik ingress controller |
| `cert-manager` | cert-manager |
| `argo` | Argo Workflow controller and batch job execution |
| `argo-events` | Argo Events |

## 10. Common kubectl one-liners

```bash
# All pods across all namespaces that are not Running or Completed
kubectl get pods -A | grep -v -E 'Running|Completed|Terminating'

# Events sorted by time (spot crashes, scheduling failures, etc.)
kubectl -n $NS get events --sort-by='.lastTimestamp' | tail -30

# Resource usage by pod
kubectl -n $NS top pods

# Resource usage by node
kubectl top nodes

# Exec into a running pod (useful for connectivity tests)
kubectl -n $NS exec -it deployment/<service> -- sh

# Copy a file out of a pod
kubectl -n $NS cp <pod>:/path/to/file ./local-file

# Port-forward a service to localhost
kubectl -n $NS port-forward svc/<service> <local-port>:<remote-port>

# Watch a deployment roll out
kubectl -n $NS rollout status deployment/<service> --watch

# Check which image version a service is currently running
kubectl -n $NS get deployment/<service> -o jsonpath='{.spec.template.spec.containers[0].image}'
```

# Citations

[1] `docs/ops-runbook.md` — source document for this page.
[2] `ansible/deploy_it.yml` — service deploy playbook referenced in §4–§6.
[3] `ansible/kubernetes.yml` — full-cluster playbook whose `configure-services` tag renders service config Secrets.
[4] `skills/resolving-the-kubeconfig/SKILL.md` — kubeconfig resolution procedure referenced in Prerequisites.
