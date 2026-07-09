---
name: adding-a-de-service-role
description: Use when adding a brand-new CyVerse DE service to the deployments repo — scaffolding roles/services/<service>/ and wiring it into cloning, building, and deploying so it behaves like the existing services.
---

# Adding a DE Service Role

## Overview

Each DE service is a self-contained role under `roles/services/<service>/`. The
generic `build-service` and `deploy-service` roles do the real work, parameterized
by `project_name`, so a service role is mostly boilerplate plus its own
`skaffold.yaml`, k8s manifest, and config template. Adding a service = **create
the role** + **wire it into four existing files**. Get every naming invariant
below to agree, or the config secret won't mount or the deploy will look for the
wrong image.

## The Naming Invariants (make these all agree)

For a service named `<svc>`:

- Role directory = `<svc>` = `project_name` = the build/deploy **tag**.
- Image = `harbor.cyverse.org/de/<svc>` (in both `skaffold.yaml` and the k8s
  manifest's `image:`). `build-service` rewrites `harbor.cyverse.org` →
  `image_registry` at build time.
- Config secret = `<svc>-configs`. Its **data key**, the **filename mounted**
  into the container (volume `items[].path` + the file under `mountPath`), and
  the config the service reads must all be the same filename.
- `skaffold.yaml` `manifests.rawYaml` points at `k8s/<svc>.yml`.

## Files to Create (the role)

```
roles/services/<svc>/
  meta/main.yml
  tasks/build.yml
  tasks/main.yml
  templates/<svc>.<ext>.j2     # config template — OMIT if the service needs no config
  files/skaffold.yaml
  files/k8s/<svc>.yml
  files/<svc>.json             # build descriptor
```

**`meta/main.yml`**
```yaml
---
dependencies:
  - role: common
```

**`tasks/build.yml`**
```yaml
---
- name: build the <svc> image
  ansible.builtin.include_role:
    name: build-service
    tasks_from: main
  vars:
    project_name: <svc>
  tags:
    - build
```

**`tasks/main.yml`** (creates the config secret, then deploys). For a service
with **no config**, drop the secret task and keep only the `include_role`
(see `maintenance-page` for that shape).
```yaml
---
- delegate_to: localhost
  environment:
    KUBECONFIG: "{{ kubeconfig }}"
  block:
    - name: create the <svc>-configs secret
      run_once: true
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: <svc>-configs
            namespace: "{{ ns }}"
          data:
            <svc>.yml: "{{ lookup('template', '<svc>.yml.j2') | b64encode }}"
      when: load_configs is undefined or (load_configs | bool)

    - ansible.builtin.include_role:
        name: deploy-service
        tasks_from: main
      vars:
        project_name: <svc>
```

**`files/skaffold.yaml`**
```yaml
apiVersion: skaffold/v3
kind: Config
metadata:
  name: <svc>
build:
  artifacts:
    - image: harbor.cyverse.org/de/<svc>
      custom:
        buildCommand: ./buildx-build.sh
        dependencies:
          paths: ["**"]
  platforms:
    - "linux/amd64"
  tagPolicy:
    gitCommit: {}
  local: {}
manifests:
  rawYaml:
    - k8s/<svc>.yml
deploy:
  kubectl: {}
```

**`files/<svc>.json`** (seed descriptor; the first push build overwrites it with
the real `<image>:<ref>@sha256:<digest>`):
```json
{"builds":[{"imageName":"harbor.cyverse.org/de/<svc>","tag":"harbor.cyverse.org/de/<svc>:main"}]}
```

**`files/k8s/<svc>.yml` and `templates/<svc>.<ext>.j2` are service-specific** —
don't hand-write from scratch. **Copy the closest existing service** (a Go
service like `app-exposer` or `data-usage-api`; a Clojure service like `terrain`)
and rename. The manifest is a `Deployment` + `Service`; keep the config-secret
volume/mount wiring consistent with the invariants above, and trim RBAC/NATS/DB
bits the service doesn't use.

## Files to Edit (the wiring — 4 points)

| File | Add | Purpose |
| --- | --- | --- |
| `roles/common/defaults/main.yml` | `- <svc>` in the `source_repos` list | so `clone_sources.yml` clones the source repo. Add `source_repo_urls` only if the repo isn't under `git@github.com:cyverse-de`. |
| `build_it.yml` | an `include_role` block with `tasks_from: build`, `apply.tags: <svc>`, and `tags: <svc>` | so `build_it.yml --tags <svc>` builds it |
| `deploy_it.yml` | `- role: services/<svc>` with `tags: <svc>` | so `deploy_it.yml --tags <svc>` deploys it |
| `kubernetes.yml` | `- role: services/<svc>` in the **Deploy all services** `roles:` list | so a full run deploys it |

`build_it.yml` block to add:
```yaml
    - ansible.builtin.include_role:
        name: services/<svc>
        tasks_from: build
        apply:
          tags: <svc>
      tags: <svc>
```

**No edit needed:** `build_release.yml` auto-discovers roles under
`roles/services/`; `kubernetes.yml`'s single-service play resolves
`services/{{ project }}` dynamically (`-e project=<svc>`); the `build-service` /
`deploy-service` roles are generic.

## Order of Operations

1. Create the role files and make the four wiring edits.
2. Clone the source repo — `cloning-de-source-repos` (its `source_repos` entry
   now exists).
3. Build and push — `building-de-service-images` (`build_it.yml --tags <svc>`).
   This rewrites `files/<svc>.json` with the real digest.
4. Review and **commit** the updated descriptor (builds never commit it).
5. Deploy — `deploying-de-services` (`deploy_it.yml --tags <svc>`).

## Common Mistakes

- **Forgetting `source_repos`.** The most-missed point — without it
  `clone_sources.yml` won't fetch the source and builds fail with "no repo".
- **Wiring only some playbooks.** All four edits are needed; a service in
  `build_it.yml` but not `deploy_it.yml`/`kubernetes.yml` builds but never deploys
  (and vice versa).
- **Mismatched config filename.** The secret data key, the volume `items[].path`,
  the `mountPath` filename, and the template output must be the same name, or the
  service won't find its config.
- **Deploying before building.** The seed descriptor has no real digest; run a
  push build first so `files/<svc>.json` points at a pushed image.
- **Hand-writing the k8s manifest.** Copy a similar service and adjust — it's
  easy to miss labels/anti-affinity/probes conventions.

## Beyond the Basic Service

A service that needs a **database**, a group_vars **enable flag**, extra
**RBAC/ServiceAccounts**, or that other services must **reach by URL**
(`baseurls_<svc>`) needs more than this scaffold — model those on the analogous
existing service (e.g. `qms` for a DB-backed service) and the `postgresql_init`
role / `service_configurations` role as applicable.
