---
type: Runbook
title: Building and Deploying Services
description: How service container images are built from source with build_it.yml and build_release.yml, and deployed with deploy_it.yml.
resource: /ansible/BUILD_DEPLOY.md
tags: [build, deploy, release, skaffold, ansible]
timestamp: 2026-09-01T00:00:00Z
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
  commit it yourself. `git_ref` may be a tag, a local branch, or a branch that
  exists only on the remote — it is resolved to a commit, falling back to
  `origin/<ref>`, before the worktree is made, so no local branch is created in
  the checkout. A ref that resolves to neither fails by name.
* Both cloning and building assume each checkout's `origin` remote is the
  `cyverse-de` repository — see [Fork checkouts build from the fork](#fork-checkouts-build-from-the-fork).
* Builds write descriptors into the service role's own `files/` directory, and
  deploys read from `build_json_dir`, which resolves to that same directory. If
  a freshly built image isn't picked up on deploy, the build most likely never
  rewrote the descriptor — a `push_images=false` run leaves it untouched by
  design.
* `build_release.yml` is best-effort: a failed service doesn't stop the others,
  and a rebuilt/skipped/failed summary is printed at the end.
* Deploys assume the cluster subsystems are already installed — see
  [PostgreSQL](/infrastructure/postgresql.md).

## Deploying the whole list

`deploy_it.yml` runs every service role in one list, and two variables change
how it handles that. Both default to the behaviour described above, so a run
that sets neither is unchanged.

| Variable | Default | Effect when set |
| --- | --- | --- |
| `deploy_wait` | `true` | `false` passes `--status-check=false`, so skaffold applies each manifest and returns instead of blocking on the rollout. The playbook then waits once for every Deployment in `ns` at the end, turning N sequential waits into one concurrent one. |
| `deploy_continue_on_error` | `false` | `true` records a failed deploy and carries on, then fails at the end naming every service that failed. |

`deploy_continue_on_error` exists because a role that fails inside a `roles:`
list aborts the play: without it, one broken service silently leaves every
service after it in the list undeployed, and the run reads as a partial
success rather than as the truncation it is.

Deploying a single service with `--tags` wants the defaults — there is nothing
to overlap, and a failure should stop the run. The batch settings are for a
full bring-up; `deploy_wait_timeout` (default 900s) bounds the single wait.

## A deploy always restarts the service, even with nothing to change

Skaffold stamps a `skaffold.dev/run-id` label — a fresh UUID per invocation —
onto the **pod template**. A pod-template change is a spec change, so
`skaffold deploy` rolls its service every time, whether or not the image or
manifest differs. Deploying without a tag therefore restarts the whole DE.

This is worth knowing rather than working around. Redeploying to restart a
service is a reasonable thing to want — services read their configuration from
the `configs` Secret through `envFrom`, and changing that Secret does not
restart anything on its own — so the behaviour is useful more often than not.
It matters mainly if you expected a no-op re-run to be free.

It can be suppressed by overriding the label
(`skaffold deploy --label skaffold.dev/run-id=<stable value>`), which makes an
unchanged service genuinely untouched. Keep any such value distinct per
service: skaffold scopes `--status-check` by this label, so one value shared
across services makes each deploy wait on all of them.

## Fork checkouts build from the fork

`clone_sources.yml` and the build role both fetch from `origin` by name, and a
`git_ref` that doesn't resolve locally is retried as `origin/<ref>`. Neither
knows about an `upstream` remote, and the remote name isn't a variable. Since
`source_repo_dir` defaults to the directory containing this repo, a fork-based
development tree sitting alongside it is picked up by default.

In that tree `origin` is the fork, so release tags cut in `cyverse-de` after the
fork was created are absent and `build_release.yml` fails on them with
`names no commit`; a branch ref resolves to the local branch, unpushed work
included. Both fetches are best-effort (`failed_when: false`), so the symptom is
a stale build or a missing ref rather than a wrong-remote error.

Keep deployment checkouts separate from development ones and pass
`-e source_repo_dir=<dir>` on every clone, build, and release run — there is no
inventory-level place it is set. `-e source_repo=<path>` overrides one service.

# Citations

[1] `ansible/BUILD_DEPLOY.md` — source document: full prerequisites, what a build does step by step, all variables, troubleshooting.
[2] `ansible/roles/build-service/`, `ansible/roles/deploy-service/` — the roles that implement builds and deploys.
[3] `ansible/deploy_it.yml` — the service list, and the post-run wait and failure report driven by `deploy_wait` / `deploy_continue_on_error`.
[4] `ansible/clone_sources.yml`, `ansible/roles/clone-sources/` — the clone playbook and role, including the `git fetch --tags --force origin` refresh of existing checkouts.
