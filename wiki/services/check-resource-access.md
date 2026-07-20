---
type: Service
title: check-resource-access
description: Build-only service role for the check-resource-access image; no config template and not wired into deploy_it.yml.
resource: /ansible/roles/services/check-resource-access
tags: [check-resource-access, build-only, permissions]
timestamp: 2026-07-20T00:00:00Z
---

check-resource-access is an unusual role containing only build machinery and a
static Kubernetes manifest. There is no `defaults/main.yml`, no config
template, and no `tasks/main.yml`; `deploy_it.yml` does not reference it —
only `build_it.yml` does (tag `check-resource-access`). The manifest describes
a configless HTTP service: two replicas with pod anti-affinity, listening on
port 60000 with liveness/readiness probes on `/debug/vars` (the Go expvar
endpoint), OTEL exporter settings from the shared `configs` secret for
[Jaeger](/infrastructure/jaeger.md), and a ClusterIP service on port 80.

## Source and image

- Source repo: [cyverse-de/check-resource-access](https://github.com/cyverse-de/check-resource-access), cloned as a sibling checkout per `source_repos` in the common role.
- Image: `harbor.cyverse.org/de/check-resource-access`, pinned by tag and digest in `files/check-resource-access.json` and pushed to [Harbor](/infrastructure/harbor.md).

## What the role contains

- `files/check-resource-access.json` — the build descriptor.
- `files/skaffold.yaml` — skaffold config building via `buildx-build.sh` and pointing at `k8s/check-resource-access.yml`.
- `files/k8s/check-resource-access.yml` — the static deployment/service manifest.
- `tasks/build.yml` — includes the shared `build-service` role.

## Building

The role can only be built, not deployed through `deploy_it.yml`:

```
ansible-playbook build_it.yml --tags check-resource-access
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) for the
build workflow and its variables (`source_repo_dir`, `git_ref`, `push_images`).

# Citations

1. `ansible/roles/services/check-resource-access/files/check-resource-access.json` — build descriptor pinning the image.
2. `ansible/roles/services/check-resource-access/files/k8s/check-resource-access.yml` — static manifest; 2 replicas, `/debug/vars` probes, OTEL env.
3. `ansible/roles/services/check-resource-access/tasks/build.yml` — the role's only tasks file; build via the `build-service` role.
4. `ansible/build_it.yml` — wires the role in for builds; `ansible/deploy_it.yml` contains no check-resource-access entry.
