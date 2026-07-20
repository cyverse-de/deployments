---
type: Runbook
title: Building and Deploying Services
description: How service container images are built from source with build_it.yml and build_release.yml, and deployed with deploy_it.yml.
resource: /ansible/BUILD_DEPLOY.md
tags: [build, deploy, release, skaffold, ansible]
timestamp: 2026-07-20T00:00:00Z
---

This repo is the source of truth for build and deploy configuration: each
service has a role under `roles/services/<service>/` whose `files/` directory
holds the canonical `skaffold.yaml` and `k8s/` manifests. Builds run against the
service's own source repository but always overlay these files — the source
repo's copies are ignored.

## Build descriptors and releases

Each service role carries a build descriptor at
`roles/services/<service>/files/<service>.json` recording the exact image that
was built: the `tag` field is `<imageName>:<git-ref>@sha256:<digest>`, pinning
both the ref and the immutable digest. Builds rewrite this file; deploys read
it. A **release** is the set of git refs recorded across every service's
descriptor.

## Common commands

```bash
# Clone every service source repo into source_repo_dir (siblings of this repo)
ansible-playbook clone_sources.yml

# Build one or more services (builds never run by default — always select)
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags app-exposer,apps

# Build at a specific ref, or without pushing (verify only)
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags formation -e git_ref=v2025.12.02
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags formation -e push_images=false

# Rebuild a whole release from the refs in the descriptors
ansible-playbook -i "$QA_INVENTORY" build_release.yml

# Deploy: reads the descriptor, runs skaffold deploy against $KUBECONFIG
export KUBECONFIG=~/.kube/qa.conf
ansible-playbook -i "$QA_INVENTORY" deploy_it.yml --tags app-exposer
```

## Key facts

* Builds need Docker with BuildKit, skaffold on `PATH`, and an existing
  `docker login` to the registry (default `harbor.cyverse.org`). A
  container-driver buildx builder (`de-builder`) is created and selected
  automatically.
* Builds check out a temporary git worktree at `git_ref`; the source checkout
  is never modified, and the changed descriptor is never committed — review and
  commit it yourself.
* Builds always write descriptors into the service role's own `files/`
  directory; deploys read from `build_json_dir`, which inventories may override
  (the QA inventory points it at a sibling `de-releases/builds` checkout). If a
  freshly built image isn't picked up on deploy, check where `build_json_dir`
  resolves.
* `build_release.yml` is best-effort: a failed service doesn't stop the others,
  and a rebuilt/skipped/failed summary is printed at the end.
* Deploys assume the cluster subsystems are already installed — see
  [PostgreSQL](/infrastructure/postgresql.md) and
  [NATS](/infrastructure/nats.md).

# Citations

[1] `ansible/BUILD_DEPLOY.md` — source document: full prerequisites, what a build does step by step, all variables, troubleshooting.
[2] `ansible/roles/build-service/`, `ansible/roles/deploy-service/` — the roles that implement builds and deploys.
