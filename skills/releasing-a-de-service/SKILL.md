---
name: releasing-a-de-service
description: Use when cutting a release of a CyVerse DE service by pushing a git tag so the GitHub Actions pipeline builds the image and commits its build descriptor to the deployments repo — e.g. tagging a release candidate, promoting to a final release, or diagnosing why a tagged build didn't update a descriptor.
---

# Releasing a DE Service

## Overview

Pushing a version tag to a DE **service source repo** triggers its
`skaffold-build` GitHub Actions workflow, which is the automated counterpart to
a manual `build_it.yml` run. The workflow calls the shared reusable workflow
`cyverse-de/github-workflows/.github/workflows/skaffold-build.yml@v0.4.0`, which:

1. Checks out the service source repo **at the tag** and the `deployments` repo.
2. Runs **this repo's** `ansible/build_it.yml` with `push_images=true` — the same
   playbook the `building-de-service-images` skill documents.
3. Pushes the image to Harbor and commits
   `updated the build descriptor for <service>` to `cyverse-de/deployments`
   (`ansible/roles/services/<service>/files/<service>.json`).

So a release is: **tag the source repo → CI builds at that tag → a descriptor
commit lands on `deployments` `main`.** Deploying that descriptor to a cluster
is a separate step (`deploying-de-services`).

## When to Use

- Cutting a release candidate or final release of a service (tag → image +
  descriptor commit).
- Diagnosing why a tagged build failed or didn't update a descriptor.
- NOT for a manual/local build of an arbitrary ref (that's
  `building-de-service-images` / `build_it.yml -e git_ref=...`), which builds
  locally and does **not** commit the descriptor.
- NOT for rebuilding a whole release from recorded refs (`rebuilding-a-de-release`).
- NOT for deploying (`deploying-de-services`).

## Choosing the Tag

The trigger regex is generic three-part semver, but DE tags encode the **date of
the next scheduled release, which is NOT today's date**. Accepted forms:

| Form | Meaning |
| --- | --- |
| `vYYYY.MM.DD-rcNN` | Release candidate for the release on `YYYY.MM.DD` (e.g. `v2026.08.04-rc02`) |
| `vYYYY.MM.DD` | Final release |
| `vYYYY.MM.DDuNN` | Update to an already-released milestone (not enabled in every repo) |

**Release cadence: the first Tuesday of every month.** The date in the tag is the
**next such release that hasn't happened yet**, so all work heading to that
release shares one milestone date regardless of when it was tagged. Example: on
2026-07-09 the July release (Tue 2026-07-07) has passed, so the next is Tue
2026-08-04 — work tagged now uses `v2026.08.04-rc##`.

Two phases:

1. **During the month — tag release candidates.** Each change destined for the
   upcoming release gets `vYYYY.MM.DD-rcNN`, incrementing `NN` for each new
   candidate in that repo. Pick the next number by looking at what already
   exists on the milestone:
   ```
   git -C <repo> tag -l "v2026.08.04*"     # existing candidates for this milestone
   ```
2. **The night before the release — promote to final.** Go through each repo that
   has a release candidate for the upcoming release and tag its shipping commit
   with the bare `vYYYY.MM.DD` (no `-rc`), e.g. `v2026.08.04`. That final tag
   fires the same build and lands the released descriptor.

If unsure which milestone is active or which commit to promote, ask — it's a
release-planning decision, not one to guess.

## Quick Reference

Run against the **service source repo** (a sibling checkout), not `deployments`.

| Goal | Command |
| --- | --- |
| Cut a release candidate | `git -C <repo> tag vYYYY.MM.DD-rcNN && git -C <repo> push origin vYYYY.MM.DD-rcNN` |
| Cut a final release | `git -C <repo> tag vYYYY.MM.DD && git -C <repo> push origin vYYYY.MM.DD` |
| Find the triggered run | `gh run list --repo cyverse-de/<repo> --workflow skaffold-build.yml --limit 1` |
| Watch it to completion | `gh run watch <run-id> --repo cyverse-de/<repo> --exit-status` |
| Confirm the descriptor landed | `gh api repos/cyverse-de/deployments/commits --jq '.[0].commit.message'` |

The tag must be pushed to the source repo (that's what triggers the build and
what gets built). The image is built from the tagged commit, so tag the commit
you intend to ship.

## What a Release Build Does

The reusable workflow (`skaffold-build.yml@v0.4.0`), on a GitHub runner:

1. Sets `SERVICE_NAME` to the caller's `service-name` input or, by default, the
   repo name.
2. Checks out the source repo at the tag and `deployments` at `main` (push
   credentials come from `releases-repo-push-token`).
3. **Verifies the service role exists** at
   `deployments/ansible/roles/services/<service>` — hard-fails if absent (a new
   service needs its role added first; see `adding-a-de-service-role`).
4. Logs in to Harbor, installs skaffold + ansible, then runs
   `build_it.yml --tags <service> -e git_ref=<tag> -e push_images=true`, building
   from the source repo checkout and pushing the image.
5. Commits the rewritten descriptor to `deployments`. The push **rebases onto the
   latest tip and retries** (up to 5 attempts), so concurrent builds of different
   services don't collide.

## The Caller Workflow (reference)

Each service repo has `.github/workflows/skaffold-build.yml` (one exception:
`get-analysis-id` keeps its as the misnamed `swagger-build.yml`) that pins the
reusable workflow and passes three secrets:

```yaml
jobs:
  call-workflow-passing-data:
    uses: cyverse-de/github-workflows/.github/workflows/skaffold-build.yml@v0.4.0
    secrets:
      harbor-username: ${{ secrets.HARBOR_USERNAME }}
      harbor-password: ${{ secrets.HARBOR_PASSWORD }}
      releases-repo-push-token: ${{ secrets.GH_DE_RELEASES_PUSH_TOKEN }}
```

`service-name`, `deployments-repo`, and `deployments-branch` are optional inputs
(default to the repo name, `cyverse-de/deployments`, and `main`).

## Prerequisites

- The service has a role under `deployments/ansible/roles/services/<service>/`
  whose name matches the repo name (or the caller passes a matching
  `service-name`). Without it the build hard-fails at "Verify the service role
  exists".
- The org-level `GH_DE_RELEASES_PUSH_TOKEN` secret is valid (see Troubleshooting).
- `gh` authenticated against `cyverse-de` for watching runs and reading commits.

## Troubleshooting

- **`Permission to cyverse-de/deployments.git denied … 403` on "Commit the
  updated descriptor".** The image built fine; only the descriptor push was
  blocked. The `GH_DE_RELEASES_PUSH_TOKEN` (an **org-level** Actions secret, so
  fixing it once covers every repo) needs both **write access to
  `cyverse-de/deployments`** and, for a classic PAT, **SSO authorization for the
  `cyverse-de` org** (Token settings → Configure SSO → Authorize). A token whose
  owner personally has repo access still 403s until the token itself is
  SSO-authorized — the classic "my account works but the token doesn't" trap.
- **`! [rejected] main -> main (fetch first)` on the descriptor push.** This is
  the concurrent-push race, fixed in `v0.4.0` by the rebase-and-retry loop. If
  you see it again, the fix regressed — check that the `v0.4.0` tag in
  `github-workflows` still points at the fixed commit. Meanwhile, re-run the
  failed job on its own; the image is already in Harbor, so only the descriptor
  commit needs to land.
- **Build succeeded but no descriptor commit appeared.** If the descriptor was
  already current for that ref, the step logs `descriptor unchanged; nothing to
  commit` and exits cleanly — that's expected, not a failure.

## Common Mistakes

- **Using today's date for the tag.** The date is the next scheduled release
  (first Tuesday of the month), not the calendar day. Check existing tags and
  continue that milestone's `-rcNN` sequence.
- **Tagging `vice-operator`.** It has no source repo of its own — it's built from
  the `app-exposer` repo. Release it by tagging `app-exposer`.
- **Expecting a manual `build_it.yml` run to publish a release.** A local build
  never commits the descriptor; only the tag-triggered CI run does. Use a manual
  build to verify a service compiles, and a tag to actually release it.
- **Tagging a service with no deployments role.** The build hard-fails up front.
  Add the role first (`adding-a-de-service-role`).
- **Confusing this with deploying.** A green release only lands a descriptor
  commit on `deployments` `main`; nothing reaches a cluster until a separate
  deploy (`deploying-de-services`).
