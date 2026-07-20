---
type: Service
title: apps
description: Clojure service managing DE app definitions, categories, and job submission, backed by the DE database.
resource: /ansible/roles/services/apps
tags: [apps, clojure, postgresql, amqp, tapis]
timestamp: 2026-07-20T00:00:00Z
---

apps manages DE application metadata (workspace categories, favorites, beta
attributes) and job submission. Its `apps.properties` config connects it to the
DE database on [PostgreSQL](/infrastructure/postgresql.md) via the JDBC
PostgreSQL driver, to [RabbitMQ](/infrastructure/rabbitmq.md), and to a wide
set of DE services: [app-exposer](/services/app-exposer.md) (JEX base URL,
`{{ baseurls_app_exposer }}/batch`), [data-info](/services/data-info.md),
[notifications](/services/notifications.md), [analyses](/services/analyses.md),
[async-tasks](/services/async-tasks.md),
[iplant-groups](/services/iplant-groups.md) (as `de_grouper`),
[metadata](/services/metadata.md), [permissions](/services/permissions.md),
[requests](/services/requests.md), and iplant-email. It also holds Tapis
API credentials and feature flags (`tapis_enabled`, `tapis_jobs_enabled`) for
HPC job routing, iRODS home/path settings, trusted Docker registries, and GPU
model lists for tools.

## Source and image

- Source repo: [cyverse-de/apps](https://github.com/cyverse-de/apps).
- Image: `harbor.cyverse.org/de/apps`, pinned in `files/apps.json` and hosted on [Harbor](/infrastructure/harbor.md).

## Configuration

`templates/apps.properties.j2` renders into the `apps-configs` secret, mounted
at `/etc/iplant/de`. The pod additionally mounts the `gpg-keys` secret at
`/etc/iplant/crypto` for the PGP keyring (`pgp_key_password`) and sets
`JAVA_TOOL_OPTIONS`. Defaults: `apps_replicas: 2` with pod anti-affinity;
listen port 60000 behind a ClusterIP service.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags apps
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/apps/templates/apps.properties.j2` — config template: DB, AMQP, Tapis, and dependent service base URLs.
2. `ansible/roles/services/apps/tasks/main.yml` — creates the `apps-configs` secret and includes `deploy-service`.
3. `ansible/roles/services/apps/templates/k8s/apps.yml.j2` — deployment; `gpg-keys` and `apps-configs` mounts, port 60000.
4. `ansible/roles/services/apps/files/apps.json` — build descriptor pinning the image.
5. `ansible/roles/services/apps/defaults/main.yml` — replica and anti-affinity defaults.
