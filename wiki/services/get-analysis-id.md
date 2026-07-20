---
type: Service
title: get-analysis-id
description: Build-only role for the get-analysis-id lookup service; it has a static manifest but no deploy tasks and is not wired into deploy_it.yml.
resource: /ansible/roles/services/get-analysis-id
tags: [get-analysis-id, analyses, build-only]
timestamp: 2026-07-20T00:00:00Z
---

get-analysis-id is an unusual role: it contains only `tasks/build.yml` — there
is no `tasks/main.yml`, no `defaults/`, no `meta/`, and no config template.
It appears in `build_it.yml` under the `get-analysis-id` tag, but it is **not**
listed in `deploy_it.yml`, so `ansible-playbook -i $INVENTORY deploy_it.yml
--tags get-analysis-id` deploys nothing. The service can be built and its image
pushed, but this repo does not currently deploy it.

Source repo: [cyverse-de/get-analysis-id](https://github.com/cyverse-de/get-analysis-id)
(listed in the common role's `source_repos`); image
`harbor.cyverse.org/de/get-analysis-id` (`v2026.08.04-rc01` pinned by digest in
the build descriptor) on [Harbor](/infrastructure/harbor.md).

## What is in the role

- `files/get-analysis-id.json` — the build descriptor consumed by the
  build-service role.
- `files/skaffold.yaml` — skaffold config (older `skaffold/v1` apiVersion,
  unlike most services which use v3) building via `buildx-build.sh`.
- `files/k8s/get-analysis-id.yml` — a *static* (untemplated) manifest: a
  2-replica Deployment with pod anti-affinity, hardcoded arg
  `--apps-user ipctest`, HTTP listener on port 60000 with probes on
  `/debug/vars`, OTEL tracing env vars, and a Service on port 80. Because the
  role has no deploy tasks, nothing in Ansible applies this manifest; it only
  serves the skaffold build/deploy path.

## Building

Build it like any other service (see
[Building and Deploying Services](/playbooks/build-and-deploy.md)):

```bash
ansible-playbook -i $INVENTORY build_it.yml --tags get-analysis-id
```

# Citations

1. `ansible/roles/services/get-analysis-id/tasks/build.yml` — the only task file; includes the build-service role.
2. `ansible/roles/services/get-analysis-id/files/get-analysis-id.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/get-analysis-id/files/k8s/get-analysis-id.yml` — static Deployment/Service manifest (`--apps-user ipctest`, port 60000).
4. `ansible/roles/services/get-analysis-id/files/skaffold.yaml` — skaffold/v1 build config.
5. `ansible/build_it.yml` — includes the role's build tasks under the `get-analysis-id` tag; `ansible/deploy_it.yml` has no entry for it.
