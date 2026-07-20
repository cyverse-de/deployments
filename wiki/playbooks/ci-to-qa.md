---
type: Runbook
title: Continuous Integration to QA
description: The tag-triggered CI path that builds service images on GitHub Actions, publishes build descriptors to de-releases, and deploys to QA via GoCD.
resource: /ansible/docs/index.md
tags: [ci, qa, github-actions, skaffold, de-releases, gocd]
timestamp: 2026-07-20T00:00:00Z
---

This is the automated build-and-deploy path for QA. Images can also be built
locally with `build_it.yml` / `build_release.yml` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md) — but the CI
path runs entirely on GitHub's systems and deploys via [GoCD](/infrastructure/gocd.md).

## Required repositories and access

* [cyverse-de/de-releases](https://github.com/cyverse-de/de-releases) — receives build descriptors in its `builds/` directory
* [cyverse-de/github-workflows](https://github.com/cyverse-de/github-workflows) — hosts the shared `skaffold-build.yml` workflow
* [cyverse-de/deployments](https://github.com/cyverse-de/deployments) — the Ansible roles that deploy the results
* Access to the CI/CD server at [cicd-qa.cyverse.org](https://cicd-qa.cyverse.org)

## The flow

1. Commit changes in a branch; merge the PR.
2. Tag the revision `v#.#.#` (or `v#.#.#-rc#`) and push the tag.
3. The push triggers the repo's `.github/workflows/skaffold-build.yml`, which
   calls the shared workflow in `cyverse-de/github-workflows` and builds the
   image on GitHub's runners.
4. The workflow writes a new build descriptor (JSON) and commits it to the
   `builds/` directory of `de-releases`. The QA inventory points
   `build_json_dir` at a local checkout of that directory, so QA deploys pick
   up the new descriptor.
5. The workflow emits a webhook to [cicd-qa.cyverse.org](https://cicd-qa.cyverse.org),
   triggering the [GoCD](/infrastructure/gocd.md) pipeline that deploys the
   service into the QA cluster.

## Wiring a repository into CI

Each deployable repo carries a `.github/workflows/skaffold-build.yml` that
triggers on `v[0-9]+.[0-9]+.[0-9]+` (and `-rc[0-9]+`) tags and calls
`cyverse-de/github-workflows/.github/workflows/skaffold-build.yml@v0.4.0`
(pin the latest tag; check the repo for newer versions), passing the
`harbor-username`, `harbor-password`, and `releases-repo-push-token` secrets.
The `build-prerelease` input is no longer used as of `v0.4.0`.

# Citations

[1] `ansible/docs/index.md` — source document: the "Continuous Integration To QA" section, including the workflow YAML example.
