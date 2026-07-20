---
type: Service
title: analyses
description: HTTP API over the DE database that serves analysis (job) records to other DE services.
resource: /ansible/roles/services/analyses
tags: [analyses, jobs, postgresql, go]
timestamp: 2026-07-20T00:00:00Z
---

The analyses service is a small HTTP API whose only configured dependency is the
DE database: its config file contains a single PostgreSQL connection URI for
`de_db_name` on the [PostgreSQL](/infrastructure/postgresql.md) DBMS host. Other
services reach it through the `baseurls_analyses` group var — notably
[apps](/services/apps.md), which sets `apps.analyses.base-url` from it.

## Source and image

- Source repo: [cyverse-de/analyses](https://github.com/cyverse-de/analyses) (cloned as a sibling checkout per `source_repos` in the common role).
- Image: `harbor.cyverse.org/de/analyses`, pinned by tag and digest in the build descriptor `ansible/roles/services/analyses/files/analyses.json` and pushed to [Harbor](/infrastructure/harbor.md).

## Configuration

The role templates `analyses.yml.j2` into the `analyses-configs` Kubernetes
secret, mounted at `/etc/iplant/de/analyses.yml` and passed via `--config`.
Group vars consumed: `dbms_connection_user`/`dbms_connection_pass`,
`pg_listen_port`, `de_db_name`, and the `dbms` inventory group for the DB host.
The pod also reads OTEL exporter settings from the shared `configs` secret for
[Jaeger](/infrastructure/jaeger.md) tracing.

## Runtime

The deployment runs `analyses_replicas` pods (default 2) with pod anti-affinity
(`analyses_pod_anti_affinity`, default true), listening on port 60000 behind a
ClusterIP service on port 80.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags analyses
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md). Builds
use `build_it.yml --tags analyses` via the role's `tasks/build.yml`.

# Citations

1. `ansible/roles/services/analyses/files/analyses.json` — build descriptor pinning the image tag and digest.
2. `ansible/roles/services/analyses/templates/analyses.yml.j2` — config template; single DE database URI.
3. `ansible/roles/services/analyses/templates/k8s/analyses.yml.j2` — deployment/service manifest, replicas, probes, OTEL env.
4. `ansible/roles/services/analyses/tasks/main.yml` — creates the `analyses-configs` secret and includes `deploy-service`.
5. `ansible/roles/common/defaults/main.yml` — `source_repos` entry establishing the source checkout name.
