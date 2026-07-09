---
name: rebuilding-a-de-release
description: Use when rebuilding a CyVerse DE release's images from source in the deployments repo — rebuilding every service (or a subset) at the exact git refs their build descriptors are pinned to, with fresh digests, via build_release.yml.
---

# Rebuilding a DE Release

## Overview

A **release** is the set of git refs recorded across every service's build
descriptor (`roles/services/<service>/files/<service>.json`). `build_release.yml`
rebuilds each selected service from source **at the ref its descriptor records**,
pushes to the registry, and rewrites the descriptor with the new digest. Because
the ref comes from each descriptor, **`git_ref` is not an input here** — this
reproduces the pinned release with fresh digests, rather than building an
arbitrary ref (that's `build_it.yml`).

**Run all commands from the `ansible/` directory.** This is build-only — it does
not touch a cluster.

## When to Use

- Reproducing a whole release (or a subset) from source with fresh digests
- Verifying that every service in a release still builds
- NOT for building an arbitrary ref of one service (use
  `building-de-service-images` / `build_it.yml` with `-e git_ref=...`)
- NOT for deploying (use `deploying-de-services`)

## Choosing the Inventory

An `-i <inventory>` is required even though the build runs locally — the play
targets `k8s_controllers[0]`. The inventory can also affect `image_registry` /
`source_repo_dir` if its group_vars set them. Don't assume one:

- If the request names an environment/inventory, or one was agreed earlier in
  this session, use it.
- Otherwise **ask the user which inventory to use before running.**

## Quick Reference

| Goal | Command |
| --- | --- |
| Rebuild the whole release | `ansible-playbook -i <inventory> build_release.yml` |
| Rebuild a subset | `ansible-playbook -i <inventory> build_release.yml -e services=formation,apps` |
| Verify the release builds (no push) | `ansible-playbook -i <inventory> build_release.yml -e push_images=false` |
| Rebuild everything from scratch | `ansible-playbook -i <inventory> build_release.yml -e force_rebuild=true` |

Subset selection is `-e services=<csv>`, **not** `--tags`. Unknown service names
**hard-fail** the run up front (`Unknown service(s): …`), so a typo aborts rather
than silently building nothing.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `services` | all | Comma-separated subset to rebuild. |
| `push_images` | `true` | Push and rewrite descriptors. When `false`, build only. |
| `force_rebuild` | `false` | Bypass skaffold's artifact cache (`--cache-artifacts=false`). |
| `image_registry` | `harbor.cyverse.org` | Target registry. |
| `source_repo_dir` | dir containing this repo | Where source repos are checked out. Match the value you cloned into. |

There is **no `git_ref`** — each service's ref is read from its descriptor.

## What a Rebuild Does

For each selected service, on localhost:

1. Reads the ref from `roles/services/<service>/files/<service>.json` — anchored
   on the image name, stripping `@sha256:<digest>` and any trailing `-dirty`
   (skaffold's mark for an image built from an uncommitted tree), recovering the
   clean tag. A descriptor with a **digest-only** tag yields no ref and the
   service is **skipped** (not built from garbage) — e.g. `vice-operator`, which
   reuses the `app-exposer` image.
2. Builds that ref via the `build-service` role (temp git worktree, overlaid
   skaffold/k8s, registry cache), pushes, and rewrites the descriptor with the
   new digest (only when pushing).

The run is **best-effort**: each service is wrapped in block/rescue, so a failure
is recorded and the loop continues. At the end it prints a **rebuilt / skipped /
failed** summary and **exits non-zero if any service failed**.

## Prerequisites

- **Docker** with BuildKit and **skaffold** on `PATH`.
- Source repos cloned under `source_repo_dir` (`cloning-de-source-repos` /
  `clone_sources.yml`). If you cloned elsewhere, pass the same
  `-e source_repo_dir=<path>`.
- For push builds, a `docker login` to the target registry already in place.

## Common Mistakes

- **Using `--tags` for a subset.** That's `build_it.yml`, whose `git_ref`
  defaults to `main` — it would build main, not the pinned release ref. For a
  release, use `build_release.yml -e services=<csv>`.
- **Expecting `git_ref` to apply.** It's ignored here; the ref is the one
  recorded in each descriptor.
- **Expecting `push_images=false` to still push.** It doesn't — these services
  build through the custom builder, which uses `docker buildx ... --load` when
  not pushing. With `push_images=false` the descriptors are left untouched.
- **Expecting a mid-run failure to roll back.** Services that succeeded before a
  failure have **already pushed** their new digests and rewritten their
  descriptors; those are not undone. Re-run with `-e services=<the failed ones>`
  after fixing the cause.
- **Expecting fresh digests to auto-deploy.** Descriptors are written into each
  service role's own `files/` dir and are **never committed**. Deploys read from
  `build_json_dir` (which an inventory may point at a separate `de-releases`
  checkout), so publish/commit the updated descriptors before deploying.
- **Treating skipped services as failures.** A digest-only descriptor (e.g.
  `vice-operator`) is intentionally skipped, not failed.
