---
type: Service
title: data-info-next
description: The Go rewrite of data-info, deployed beside the Clojure service with nothing routed to it so the two can be diffed against a real data store.
resource: /ansible/roles/services/data-info-next
tags: [data, irods, icat, files, de, golang, migration]
timestamp: 2026-08-21T00:00:00Z
---

data-info-next is [data-info](/services/data-info.md) rewritten in Go, running
as a second Deployment and Service so the two can be compared on a live
cluster. Nothing routes to it: no other service names it, and it exists to be
driven by the rewrite's shadow/diff harness, which sends the same request to
both and compares the responses and the resulting state. It is **temporary** —
at cutover the data-info role adopts this role's config template and manifest
and this one is deleted.

It reads the same [iRODS](/infrastructure/irods.md) and ICAT
[PostgreSQL](/infrastructure/postgresql.md) credentials as data-info, and calls
the same [async-tasks](/services/async-tasks.md),
[notifications](/services/notifications.md) and
[metadata](/services/metadata.md) services. **It writes to whatever data store
the environment points at**, which is why it is off unless asked for by name.

- Source: [cyverse-de/data-info](https://github.com/cyverse-de/data-info) on the `golang` branch (`data_info_next_git_ref`), cloned separately as `data-info-next` because `build_release.yml` resolves each service's repo from the service's own name. Image `harbor.cyverse.org/de/data-info-next` from [Harbor](/infrastructure/harbor.md).
- Config: `data-info.yml.j2` — YAML, not the properties file — templated into the `data-info-next-configs` secret and mounted at `/etc/iplant/de/data-info.yml`. It translates every setting from `data-info.properties.j2`, so the two must be kept in step by hand until cutover.
- Runtime: 1 replica (`data_info_next_replicas`), no anti-affinity, port 60000. It uses roughly a quarter of the JVM service's memory. Liveness and the startup gate poll `/healthz`, which touches no backend; only readiness (`/readyz`) checks iRODS and the catalog.
- Enablement: `data_info_next_enabled` defaults to **false**. Without it `deploy_it.yml --tags data-info-next` does nothing.

Build with `ansible-playbook -i $INVENTORY build_it.yml --tags data-info-next`
and deploy with `deploy_it.yml --tags data-info-next` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md). It is
deliberately absent from `kubernetes.yml`'s deploy-all list.

## Two things this role does differently, and why

**It builds from `Dockerfile.golang`, not `Dockerfile`.** Both trees live in
the same checkout until cutover, so data-info builds the Clojure image and
data-info-next builds the Go one from the same commit — which is what makes a
difference between the two a difference in the code rather than in what was
built. The shared `buildx-build.sh` hardcodes `--file "$BUILD_CONTEXT/Dockerfile"`,
so this role's `skaffold.yaml` uses skaffold's own docker builder to name the
other file. At cutover the Go Dockerfile takes the plain name back and the
custom builder returns.

**Its pod gets `terminationGracePeriodSeconds: 120` and a 5-second `preStop`
sleep**, where data-info runs on Kubernetes' 30-second default. On SIGTERM the
service stops accepting requests, cancels its in-flight move/rename/delete jobs
and waits for each to post a terminal status to
[async-tasks](/services/async-tasks.md) — and that post carries the end date
that releases the job's path lock. A SIGKILL in the middle of it leaves those
paths locked against every later request. The binary budgets 30 seconds for the
listener and 60 for the jobs, which is why the grace period has to be this
generous.

# Citations

1. `ansible/roles/services/data-info-next/templates/data-info.yml.j2` — the YAML config, translated from data-info's properties template.
2. `ansible/roles/services/data-info-next/templates/k8s/data-info-next.yml.j2` — Deployment/Service, probes, grace period and preStop.
3. `ansible/roles/services/data-info-next/files/skaffold.yaml` — the native docker builder naming `Dockerfile.golang`.
4. `ansible/roles/services/data-info-next/defaults/main.yml` — `data_info_next_enabled`, `data_info_next_replicas`, `data_info_next_git_ref`.
5. `ansible/roles/common/defaults/main.yml` — the `source_repos` entry and its `source_repo_urls` override.
