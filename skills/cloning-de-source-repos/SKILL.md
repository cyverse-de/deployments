---
name: cloning-de-source-repos
description: Use when cloning the CyVerse DE service source repositories from the deployments repo — e.g. "clone the source repos", setting up the sibling checkouts that image builds need before running build_it.yml or build_release.yml.
---

# Cloning DE Source Repositories

## Overview

Building DE service images needs each service's **source repo** checked out
locally. The `clone_sources.yml` playbook clones all of them (~48 repos) into
`source_repo_dir`, skipping any already present. It runs entirely on localhost
and needs **no inventory**.

**Run the command from the `ansible/` directory.**

## When to Use

- Setting up the source checkouts before building images
- Refreshing tags on already-cloned repos (a release builds from tags)
- NOT for building or deploying — this only clones/updates source repos

## Choosing Where to Store the Repos

The repos land in `source_repo_dir`. Its default is the directory **containing**
the deployments repo (so the checkouts are siblings), which is what builds
expect — but cloning ~48 repos is a real filesystem side effect, so pick the
location deliberately:

- If the request names a location, or one was agreed earlier in this session,
  use it (`-e source_repo_dir=<path>`).
- Otherwise **ask the user where to store the repos before running.** You may
  offer the default (siblings of the deployments repo) as the suggested choice,
  but do not silently default to it. When you ask, also ask **whether the choice
  should apply to the rest of the session.**

**Whatever location you choose, builds must use the same `source_repo_dir`.**
`build_it.yml` / `build_release.yml` default it to the deployments repo's
siblings; if you clone elsewhere, pass the same `-e source_repo_dir=<path>` to
the build commands or they won't find the sources.

## Quick Reference

```bash
# from the ansible/ directory; no inventory needed
ansible-playbook clone_sources.yml -e source_repo_dir=<path>

# clone over HTTPS instead of SSH
ansible-playbook clone_sources.yml -e source_repo_dir=<path> \
  -e cyverse_repo_base=https://github.com/cyverse-de
```

## What It Does

1. Ensures `source_repo_dir` exists.
2. Clones each repo in `source_repos` to `<source_repo_dir>/<repo>`, **skipping
   any already cloned** (checks for `<repo>/.git`). Idempotent — it never
   re-clones or modifies an existing checkout's working tree.
3. For repos already present, runs `git fetch --tags --force origin` to refresh
   tags/branches. Non-destructive: it updates refs only, not the tree.

Clone URLs default to SSH (`git@github.com:cyverse-de/<repo>`). Per-repo
overrides live in `source_repo_urls` (currently only `qms`, which is in the
`cyverse` org).

## Authentication

- **SSH (default):** needs a configured GitHub SSH key. Some repos are private.
- **HTTPS:** set `-e cyverse_repo_base=https://github.com/cyverse-de` and use a
  credential helper (e.g. `gh auth setup-git`) for the private repos.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `source_repo_dir` | dir containing this repo (siblings) | Where the repos are cloned. |
| `cyverse_repo_base` | `git@github.com:cyverse-de` | Default org base URL; set to the HTTPS base for HTTPS clones. |
| `source_repos` | list in `common` | The repos to clone. |
| `source_repo_urls` | `{qms: cyverse/qms}` | Per-repo URL overrides for repos not under `cyverse_repo_base`. |
