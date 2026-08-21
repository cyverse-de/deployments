---
type: Runbook
title: Continuous Integration Builds
description: The tag-triggered CI path that builds a service image on GitHub Actions and commits the updated build descriptor back to the deployments repo.
resource: /ansible/docs/index.md
tags: [ci, qa, github-actions, skaffold, descriptors]
timestamp: 2026-08-21T00:00:00Z
---

This is the automated build path. Images can also be built locally with
`build_it.yml` / `build_release.yml` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md) — but the CI
path runs entirely on GitHub's runners and needs no local checkout.

## Required repositories and access

* [cyverse-de/github-workflows](https://github.com/cyverse-de/github-workflows) — hosts the shared `skaffold-build.yml` workflow
* [cyverse-de/deployments](https://github.com/cyverse-de/deployments) — holds the service roles the workflow builds from and commits back to

## The flow

1. Commit changes in a branch; merge the PR.
2. Tag the revision `v#.#.#` (or `v#.#.#-rc#`) and push the tag.
3. The push triggers the repo's `.github/workflows/skaffold-build.yml`, which
   calls the shared workflow in `cyverse-de/github-workflows`.
4. The shared workflow checks out the service source **and** the deployments
   repo, then runs
   `build_it.yml --tags <service> -e source_repo=... -e git_ref=<tag> -e push_images=true`
   against the checked-out roles. The image is pushed to
   [Harbor](/infrastructure/harbor.md).
5. It commits the rewritten
   `ansible/roles/services/<service>/files/<service>.json` back to the
   deployments repo's `main` branch. Concurrent builds race for that branch, so
   the step rebases and retries up to five times before failing; distinct
   services touch distinct files, so the rebase applies cleanly.

The workflow fails early if no service role matches the name, since
`build_it.yml` would otherwise match no `--tags` and silently build nothing.
Pass `service-name` when the source repo's name differs from the role's, and
`extra-service-names` when one image serves several roles — that is how
`vice-operator` mirrors `app-exposer`.

Deploying what CI built is a separate step: `deploy_it.yml --tags <service>`
reads the descriptor from that same `files/` directory, so pull `main` first.

> **The workflow no longer deploys.** Through `v0.3`, the last step emitted a
> webhook to `cicd-qa.cyverse.org` that triggered a [GoCD](/infrastructure/gocd.md)
> pipeline, and descriptors landed in a separate `de-releases` repository that
> the QA inventory pointed `build_json_dir` at. Neither is true of `v0.4.0`:
> the descriptor commit is where the workflow ends, and `de-releases` is
> retired. What now picks the descriptor up for QA is not described by the
> workflow itself — confirm it before relying on a tag push alone to deploy.

## Wiring a repository into CI

Each deployable repo carries a `.github/workflows/skaffold-build.yml` that
triggers on `v[0-9]+.[0-9]+.[0-9]+` (and `-rc[0-9]+`) tags and calls
`cyverse-de/github-workflows/.github/workflows/skaffold-build.yml@v0.4.0`
(pin the latest tag; check the repo for newer versions), passing the
`harbor-username`, `harbor-password`, and `releases-repo-push-token` secrets.
The `build-prerelease` input is no longer used as of `v0.4.0`.

`releases-repo-push-token` keeps the name it had when descriptors lived in a
separate releases repository, and is fed from the org-level
`GH_DE_RELEASES_PUSH_TOKEN`. The names are historical; the token pushes to the
deployments repo, and needs write access to it.

# Citations

[1] `ansible/docs/index.md` — source document: the "Continuous Integration To QA" section, including the workflow YAML example.
[2] [`cyverse-de/github-workflows` `.github/workflows/skaffold-build.yml`](https://github.com/cyverse-de/github-workflows/blob/main/.github/workflows/skaffold-build.yml) — the shared workflow's actual steps at `v0.4.0`.
