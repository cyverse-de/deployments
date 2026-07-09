---
name: deploying-de-services
description: Use when deploying one or more CyVerse DE services to a cluster from the deployments repo — e.g. "deploy terrain", rolling out a freshly built image, or pushing several services to QA/prod/local with deploy_it.yml.
---

# Deploying DE Services

## Overview

In the CyVerse DE `deployments` repo, each service has a role under
`ansible/roles/services/<service>/`. Deploying a service reads its **build
descriptor** (`<service>.json`, which pins an exact image digest) and runs
`skaffold deploy` against the target cluster using the canonical
`skaffold.yaml` and `k8s/` manifests from the role. The `deploy_it.yml`
playbook deploys services selected by tag.

**Run all commands from the `ansible/` directory.**

## When to Use

- Deploying one or more DE services after building/pushing new images
- Rolling out a service to QA, prod, or a local cluster
- NOT for building images (that's `building-de-service-images` /
  `build_it.yml`), and NOT for a full first-time environment stand-up (that's
  `kubernetes.yml` with `configure-services` + `deploy-all-services`)

## Choosing the Environment

A deploy targets **two** things that must both resolve to the *same intended
environment*: the **inventory** (`-i`) and the **kubeconfig** (which cluster).

### Inventory

- If the request names an environment/inventory, or one was agreed earlier in
  this session, use it.
- Otherwise **ask which inventory to use before running.**
- **Deploying to production requires explicit approval** — confirm first, never
  default to prod.

### Kubeconfig (target cluster)

**REQUIRED SUB-SKILL:** Resolve which cluster to deploy to with
`resolving-the-kubeconfig` before running — the target comes from a
session-agreed value, the inventory group_vars, or the `KUBECONFIG` env var, and
`KUBECONFIG` alone does not guarantee the cluster you'll hit. Ask the user when
the value is ambiguous; never write it to memory.

## Quick Reference

```bash
# resolve the target cluster first (see Choosing the Environment); if the
# session uses the env var, e.g.
export KUBECONFIG=~/.kube/qa.conf
```

| Goal | Command |
| --- | --- |
| Deploy one service | `ansible-playbook -i <inventory> deploy_it.yml --tags terrain` |
| Deploy several | `ansible-playbook -i <inventory> deploy_it.yml --tags terrain,sonora` |
| Deploy image only (skip config re-render) | `... deploy_it.yml --tags terrain -e load_configs=false` |

Selection is by **tag**, and each service's tag equals its role name.
`--tags` order does **not** control sequencing — services run in the fixed
order declared in `deploy_it.yml`.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `kubeconfig` | `$KUBECONFIG` env → `~/.kube/config`; overridable in inventory group_vars | Cluster to deploy to. Resolve it with `resolving-the-kubeconfig`. |
| `ns` | `qa` (overridden by inventory) | Target namespace. |
| `deploy_ns` | `ns` | Per-deploy namespace override, if set. |
| `build_json_dir` | the service role's own `files/` dir | Directory deploys **read** descriptors from. Inventories may override it (QA points it at a sibling `de-releases/builds` checkout). |
| `load_configs` | `true` | Whether to (re)render the per-service `<service>-configs` secret. Set `false` to deploy the image without touching config. |
| `deploy_profile` | unset | Optional skaffold profile, if a role defines one. |

## What a Deploy Does

For each selected service, entirely on localhost with `KUBECONFIG` set:

1. Renders the role's config template into the `<service>-configs` **secret** in
   `ns` (skipped when `load_configs=false`).
2. The `deploy-service` role reads `<build_json_dir>/<service>.json` and runs
   `skaffold deploy --namespace <ns> --build-artifacts <descriptor> --force
   --kubeconfig <kubeconfig>` from the role's `files/` dir. Because it passes the
   descriptor as a build artifact, the cluster gets **exactly the pinned digest**
   — not a floating tag — plus the canonical `k8s/` manifests from the role.

## Prerequisites

- **skaffold** on `PATH` and the `kubernetes.core` Ansible collection installed
  (`ansible-galaxy install -r requirements.yml`).
- `KUBECONFIG` pointing at the intended cluster (see **Choosing the
  Environment**).
- The environment must already be **configured**: `deploy_it.yml` does **not**
  create the shared `configs` secret (or the `java-tool-options` configmap,
  portal-conductor cert, etc.). Those come from the `configure-services` step
  (`service_configurations` role) in `kubernetes.yml`. Deploying a service into a
  namespace where that step hasn't run will start pods that can't mount `configs`.
- The inventory must define the `k8s_controllers` group (the play targets
  `k8s_controllers[0]` even though every task runs locally).

## Common Mistakes

- **Deploying a stale digest after a build.** Builds **write** the descriptor
  into the service role's own `files/` dir, but deploys **read** from
  `build_json_dir`, which an inventory may override to a separate
  `de-releases/builds` checkout. If a freshly built image isn't picked up,
  confirm the new descriptor was published to the location `build_json_dir`
  resolves to (and that checkout is pulled up to date) — otherwise the deploy
  ships the old digest.
- **Clobbering hand-patched config.** With `load_configs` on (the default), the
  deploy re-renders `<service>-configs` from the current inventory, reverting any
  in-cluster edits. Use `-e load_configs=false` to deploy the image only.
- **Deploying to the wrong cluster/namespace.** `KUBECONFIG` and `-i <inventory>`
  are independent — if they point at different environments the deploy lands
  somewhere unintended. Confirm both target the same environment before running.
- **Assuming the tag order is the deploy order.** It isn't; order is fixed in
  `deploy_it.yml`. This only matters if you expected sequencing between services.
