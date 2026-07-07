# Building and Deploying Services

This document describes how service container images are built from source and
deployed to a cluster from this repository.

## Concepts

### The deployments repo is the source of truth

Each service has a role under `roles/services/<service>/`. The role's `files/`
directory holds the canonical `skaffold.yaml` and `k8s/` manifests for that
service. Builds run against the service's own **source** repository, but the
`skaffold.yaml` and `k8s/` files are always taken from the service role here —
the source repo's copies are ignored. This keeps build/deploy configuration in
one place.

### Build descriptors

Each service role carries a build descriptor at
`roles/services/<service>/files/<service>.json`. It records the exact image that
was built:

```json
{"builds":[{"imageName":"harbor.cyverse.org/de/app-exposer",
            "tag":"harbor.cyverse.org/de/app-exposer:v2026.06.02@sha256:36f1..."}]}
```

The `tag` field is `<imageName>:<git-ref>@sha256:<digest>`, so it pins both the
human-readable ref the image was built from and the immutable content digest.
Builds rewrite this file; deploys read it.

### A "release"

A release is the set of git refs recorded across every service's build
descriptor. Rebuilding a release means rebuilding each service's source at the
ref named in its descriptor (see [Rebuilding a release](#rebuilding-a-release)).

### Source repositories and `source_repo_dir`

Builds need each service's source checked out locally. By default they are
expected as siblings of this repo:

```
<source_repo_dir>/            # default: the directory containing this repo
├── deployments/              # this repo
├── app-exposer/
├── formation/
└── ...
```

`source_repo_dir` defaults to the directory that contains this repo
(`{{ playbook_dir }}/../..`). The per-service path defaults to
`<source_repo_dir>/<service>` and can be overridden with `source_repo` when a
checkout lives elsewhere or under a different name.

## Prerequisites

- **Docker** with **BuildKit** available, and **skaffold** on `PATH`.
- A **container-driver `buildx` builder** for push builds. Each service builds
  through a custom builder (`roles/build-service/files/buildx-build.sh`) that
  reads and writes a `<image>:cache` registry layer cache, and exporting that
  cache needs a container-driver builder — the default `docker` driver cannot.
  The build role creates and selects a `de-builder` builder automatically; you
  only need `docker buildx` available. (Build-only/verify runs that don't push
  skip the cache export and work on any builder.)
- A `docker login` to the target registry (default `harbor.cyverse.org`) must
  already be in place — pushes use the ambient Docker credentials.
- The service source repos cloned under `source_repo_dir`
  (see [Cloning the source repositories](#cloning-the-source-repositories)).
- For deploys, `KUBECONFIG` pointing at the target cluster.

The examples below use `$QA_INVENTORY` for the path to the private inventory
directory; see `.env.sample` for the environment variables a deployment shell
typically sets.

## Cloning the source repositories

`clone_sources.yml` clones every service's source repo into `source_repo_dir`,
skipping any that are already cloned. It runs entirely on the local machine and
needs no inventory:

```bash
ansible-playbook clone_sources.yml
```

- Already-cloned repos are left untouched, but their tags/branches are refreshed
  (`git fetch --tags`) since releases build from tags.
- Most repos live under the `cyverse-de` org; per-repo exceptions (e.g. `qms`,
  which lives in the `cyverse` org) are handled by `source_repo_urls`.
- Clones default to SSH (`git@github.com:cyverse-de`), so a GitHub SSH key must
  be configured. To clone over HTTPS instead, set
  `-e cyverse_repo_base=https://github.com/cyverse-de` (and a credential helper
  such as `gh auth setup-git` for private repos).

The repo list (`source_repos`), default org (`cyverse_repo_base`), and overrides
(`source_repo_urls`) are defined in the `common` role's defaults.

## Building images

Builds **never run by default** — they are gated behind tags or an explicit
service selection. Two playbooks cover the build paths:

| Playbook | Use | Selection |
| --- | --- | --- |
| `build_it.yml` | Build one or more services | `--tags <service>` |
| `build_release.yml` | Rebuild a whole release from descriptor refs | `-e services=<csv>` (optional) |

### Build a single service

```bash
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags app-exposer
```

Build several at once by repeating the tag:

```bash
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags app-exposer,apps
```

### Build at a specific ref

```bash
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags formation -e git_ref=v2025.12.02
```

### Build without pushing (verify only)

```bash
ansible-playbook -i "$QA_INVENTORY" build_it.yml --tags formation -e push_images=false
```

With `push_images=false` the image is built but not pushed, and the descriptor
is left untouched (an unpushed image has no registry digest to record).

### What a build does

For each selected service the `build-service` role:

1. Asserts the source repo exists at `source_repo` (fails with guidance if not).
2. Creates a temporary git **worktree** checked out at `git_ref` — the source
   checkout itself is never modified.
3. `git fetch --tags` first, so a requested release tag resolves even if the
   clone is stale.
4. Overlays the service role's `skaffold.yaml`, `k8s/`, and the shared
   `buildx-build.sh` onto the worktree.
5. Rewrites `harbor.cyverse.org` in the overlaid skaffold config to
   `image_registry`.
6. Ensures a container-driver `de-builder` buildx builder exists and selects it.
7. Runs `skaffold build` (with `--cache-artifacts=false` when `force_rebuild`,
   and `--push --file-output <descriptor>` when `push_images`, `--push=false`
   otherwise — skaffold relays the flag to the builder as `PUSH_IMAGE`, so a
   no-push build loads the image locally instead of pushing). The skaffold
   config uses a custom builder that runs `buildx-build.sh`, which builds with
   `docker buildx` and a **mode=max `<image>:cache` registry layer cache** — so
   the dependency-download stage of multi-stage builds (e.g. Clojure
   Maven/Clojars) is reused across builds instead of re-fetched from upstream.
   The cache is read on every build and re-exported only on a push build.
8. Rewrites `roles/services/<service>/files/<service>.json` with the new digest
   (only when pushing).
9. Removes the worktree and temp directory.

A service can build from another service's source repo: `source_service`
(default: the service's own name) names the repo the build checks out. The only
current override is `vice-operator`, whose role builds the `app-exposer` repo.

The build **never commits** the changed descriptor — review and commit it
yourself.

> The descriptor is always written into the service role's own `files/`
> directory, computed from `playbook_dir`, independent of any `build_json_dir`
> override (see [Descriptor locations](#descriptor-locations-build-vs-deploy)).

## Rebuilding a release

`build_release.yml` rebuilds the images for a release. For each service it reads
the git ref from the service's descriptor, builds the source at that ref, pushes
to the registry, and rewrites the descriptor with the new digest. The ref comes
from the descriptor, so `git_ref` is not an input here.

```bash
# rebuild the entire release
ansible-playbook -i "$QA_INVENTORY" build_release.yml

# rebuild a subset
ansible-playbook -i "$QA_INVENTORY" build_release.yml -e services=formation,apps

# rebuild everything from scratch, without pushing (verify the release builds)
ansible-playbook -i "$QA_INVENTORY" build_release.yml -e force_rebuild=true -e push_images=false
```

The rebuild is **best-effort**: a service that fails does not stop the others.
At the end it prints a summary of rebuilt / skipped / failed services and exits
non-zero if any failed. A service whose descriptor has no resolvable ref (e.g.
`vice-operator`, which reuses the app-exposer image and has a digest-only tag)
is **skipped** rather than built from garbage.

The `-dirty` suffix that skaffold appends when an image was built from an
uncommitted tree is stripped during ref extraction, so a descriptor recording
`v2026.06.02-dirty` rebuilds from the clean `v2026.06.02` tag.

## Deploying services

Deploys read the build descriptor and run `skaffold deploy` against the cluster
named by `KUBECONFIG`.

| Playbook | Use | Selection |
| --- | --- | --- |
| `deploy_it.yml` | Deploy one or more services | `--tags <service>` |

```bash
export KUBECONFIG=~/.kube/qa.conf
ansible-playbook -i "$QA_INVENTORY" deploy_it.yml --tags app-exposer
```

The deploy reads `<build_json_dir>/<service>.json`, then runs
`skaffold deploy --build-artifacts <descriptor>` so the cluster gets exactly the
digest recorded in the descriptor.

## Variables

| Variable | Default | Applies to | Meaning |
| --- | --- | --- | --- |
| `source_repo_dir` | dir containing this repo (`../..`) | build, clone | where source repos are checked out |
| `source_repo` | `<source_repo_dir>/<source_service>` | build | exact path to a service's source repo |
| `source_service` | the service's own name | build | which service's source repo to build from (e.g. `vice-operator` builds `app-exposer`) |
| `git_ref` | `main` | `build_it` | git ref to build (release builds read it from the descriptor) |
| `image_registry` | `harbor.cyverse.org` | build | target registry; rewritten into skaffold config |
| `force_rebuild` | `false` | build | bypass skaffold's artifact cache (`--cache-artifacts=false`) |
| `push_images` | `true` | build | push and update the descriptor; when `false`, build only |
| `services` | all | `build_release` | comma-separated subset to rebuild |
| `cyverse_repo_base` | `git@github.com:cyverse-de` | clone | default org base URL for clone URLs (SSH; override for HTTPS) |
| `source_repos` | list in `common` | clone | repos to clone into `source_repo_dir` |
| `source_repo_urls` | `{qms: cyverse/qms}` | clone | per-repo clone-URL overrides |
| `build_json_dir` | the service role's `files/` dir | deploy | directory deploys read descriptors from; inventories may override it (QA points at a `de-releases/builds` checkout) |

## Notes and troubleshooting

### Descriptor locations: build vs. deploy

Builds always **write** the descriptor into the service role's own `files/`
directory. Deploys **read** from `build_json_dir`, which inventories may override
to point at a separate releases checkout (the QA inventory points it at a sibling
`de-releases/builds` directory). If a freshly built image isn't picked up on
deploy, confirm the descriptor was published to the location `build_json_dir`
resolves to.

### A release tag won't check out

Release builds use git tags. If a tag isn't found, the local clone is likely
stale — re-run `clone_sources.yml` (which fetches tags for existing checkouts),
or `git fetch --tags` in the source repo. Builds fetch tags automatically before
checkout, so this is usually a clone that predates that behavior.

### An upstream build is broken

Some failures originate in the service's own source (e.g. a Dockerfile pulling
an unpinned `@latest` tool that drifted past the pinned base image). These must
be fixed and re-tagged in the service repo — they cannot be fixed here.
