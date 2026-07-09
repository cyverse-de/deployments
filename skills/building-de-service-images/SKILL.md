---
name: building-de-service-images
description: Use when building, rebuilding, or verifying a CyVerse DE service container image from source in the deployments repo — e.g. "build the formation image", building at a specific git tag, or checking that a service still builds without pushing.
---

# Building DE Service Images

## Overview

In the CyVerse DE `deployments` repo, each service has a role under
`ansible/roles/services/<service>/`. Images are built from the service's **own
source repo** (a sibling checkout), but the `skaffold.yaml` and `k8s/` manifests
always come from the service role here — the deployments repo is the source of
truth. Builds are driven by the `build_it.yml` playbook and gated behind tags.

**Run all commands from the `ansible/` directory.**

## Choosing the Inventory

Every command needs `-i <inventory>` pointing at the private inventory for the
**target environment** (QA, prod, local, …). The inventory determines which
cluster and registry you act on, so never assume one:

- If the request names an environment/inventory, or one was already agreed
  earlier in this session, use that.
- Otherwise **ask the user which environment/inventory to use before running.**
  Do not default to a `$QA_INVENTORY` (or any other) env var — different
  environments use different inventory paths and different variables.

The examples below write `-i <inventory>` for this reason; substitute the
inventory you were given or agreed on.

## When to Use

- Building one or more DE service images from source
- Verifying a service still builds (no push) after a change
- Building a service at a specific git tag/ref
- NOT for deploying (that's `deploy_it.yml`) or rebuilding a whole release
  from recorded refs (that's `build_release.yml`, which reads each ref from the
  service's descriptor instead of taking `git_ref`)

## Quick Reference

| Goal | Command |
| --- | --- |
| Build one service | `ansible-playbook -i <inventory> build_it.yml --tags formation` |
| Build several at once | `ansible-playbook -i <inventory> build_it.yml --tags terrain,apps` |
| Build at a specific ref | `... build_it.yml --tags formation -e git_ref=v2025.12.02` |
| Verify only (no push) | `... build_it.yml --tags formation -e push_images=false` |
| Bypass skaffold's cache | `... build_it.yml --tags formation -e force_rebuild=true` |

Selection is by **tag**, and each service's tag equals its role name. Builds
**never run by default** — with no `--tags` nothing builds.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `git_ref` | `main` | Git ref to build. Applies to the **whole invocation** — every tag in one run builds the same ref. |
| `push_images` | `true` | Push the image and rewrite the descriptor. When `false`, build only. |
| `force_rebuild` | `false` | Pass `--cache-artifacts=false` to bypass skaffold's artifact cache. |
| `image_registry` | `harbor.cyverse.org` | Target registry, rewritten into the skaffold config. |
| `source_repo_dir` | dir containing this repo | Where source repos are checked out (siblings by default). |
| `source_repo` | `<source_repo_dir>/<source_service>` | Exact path to a service's source repo; override when the checkout name differs. |
| `source_service` | the service's own name | Which repo to build from. Only override in play is `vice-operator`, which builds the `app-exposer` repo. |

## What a Build Does

For each selected service the `build-service` role, entirely on localhost:

1. Asserts the source repo exists at `source_repo` (fails with guidance if not).
2. `git fetch --tags --force`, then creates a temporary detached **git
   worktree** at `git_ref` — your actual checkout is never modified.
3. Overlays the role's `skaffold.yaml`, `k8s/`, and the shared `buildx-build.sh`
   onto the worktree, and rewrites `harbor.cyverse.org` → `image_registry`.
4. Ensures a container-driver `de-builder` buildx builder exists and selects it.
5. Runs `skaffold build` through a custom builder (`buildx-build.sh`) that uses a
   mode=max `<image>:cache` registry layer cache — so multi-stage dependency
   downloads (e.g. Clojure Maven/Clojars) are reused instead of re-fetched. On a
   push build it adds `--push --file-output <descriptor>`; otherwise `--load`.
6. Rewrites `roles/services/<service>/files/<service>.json` with the new digest
   — **only when pushing**.
7. Removes the worktree and temp dir.

## Prerequisites

- **Docker** with BuildKit and **skaffold** on `PATH`.
- The service source repos cloned under `source_repo_dir` (run
  `ansible-playbook clone_sources.yml` if missing — no inventory needed).
- For **push** builds, a `docker login` to the target registry already in place.
  A verify-only (`push_images=false`) build needs no login and no registry.
- An `-i <inventory>` is required even though every task runs locally — the
  play targets `k8s_controllers[0]`. See **Choosing the Inventory** above; some
  shells export the path as an env var (e.g. `$QA_INVENTORY`, see
  `ansible/.env.sample`), but confirm the environment rather than assuming one.

## Common Mistakes

- **Expecting `push_images=false` to still push.** For these services it does
  **not** push — the custom builder runs `docker buildx ... --load` when
  `PUSH_IMAGE` isn't true. (An older BUILD_DEPLOY.md caveat about the default
  skaffold local builder pushing anyway does not apply here; all 48 services use
  the custom builder.) With `push_images=false` the descriptor is left untouched,
  since an unpushed image has no registry digest to record.
- **Building services at different refs in one run.** `git_ref` applies to the
  whole invocation. For different refs, run them separately.
- **Committing expectations.** The build **never commits** the changed
  descriptor — review and commit `files/<service>.json` yourself.
- **Looking for the descriptor in a de-releases checkout.** Builds always
  **write** into the service role's own `files/` dir, regardless of any
  `build_json_dir` override (that override only affects where *deploys* read).
- **A release tag won't check out.** Usually a stale clone. Builds auto-fetch
  tags, but re-run `clone_sources.yml` (or `git fetch --tags` in the source repo)
  if a tag still won't resolve.
