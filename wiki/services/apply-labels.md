---
type: Service
title: apply-labels
description: Build-only service role for the apply-labels image; it has no config template and is not wired into deploy_it.yml.
resource: /ansible/roles/services/apply-labels
tags: [apply-labels, build-only, vice]
timestamp: 2026-07-20T00:00:00Z
---

apply-labels is an unusual role: it contains only build machinery and a static
Kubernetes manifest. There is no `defaults/main.yml`, no config template, and
no `tasks/main.yml`, and `deploy_it.yml` does not reference it — only
`build_it.yml` does (tag `apply-labels`). The manifest shows a configless HTTP
service: a single-replica deployment listening on port 60000 with liveness and
readiness probes on `/`, fronted by a ClusterIP service on port 80, with the
timezone configmap as its only external input.

## Source and image

- Source repo: [cyverse-de/apply-labels](https://github.com/cyverse-de/apply-labels), cloned as a sibling checkout per `source_repos` in the common role.
- Image: `harbor.cyverse.org/de/apply-labels`, pinned by tag and digest in `files/apply-labels.json` and pushed to [Harbor](/infrastructure/harbor.md).

## What the role contains

- `files/apply-labels.json` — the build descriptor.
- `files/skaffold.yaml` — skaffold config building the image via `buildx-build.sh` and pointing at `k8s/applylabels.yml`.
- `files/k8s/applylabels.yml` — the static deployment/service manifest.
- `tasks/build.yml` — includes the shared `build-service` role.

## Building

The role can only be built, not deployed through `deploy_it.yml`:

```
ansible-playbook build_it.yml --tags apply-labels
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) for the
build workflow and its variables (`source_repo_dir`, `git_ref`, `push_images`).

# Citations

1. `ansible/roles/services/apply-labels/files/apply-labels.json` — build descriptor pinning the image.
2. `ansible/roles/services/apply-labels/files/k8s/applylabels.yml` — static manifest; single replica, port 60000, no config mounts.
3. `ansible/roles/services/apply-labels/tasks/build.yml` — the role's only tasks file; build via the `build-service` role.
4. `ansible/build_it.yml` — wires the role in for builds; `ansible/deploy_it.yml` contains no apply-labels entry.
