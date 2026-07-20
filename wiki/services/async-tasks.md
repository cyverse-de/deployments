---
type: Service
title: async-tasks
description: HTTP API for tracking asynchronous DE tasks, configured with the shared jobservices.yml config.
resource: /ansible/roles/services/async-tasks
tags: [async-tasks, jobs, postgresql, amqp]
timestamp: 2026-07-20T00:00:00Z
---

async-tasks provides the DE's asynchronous-task tracking API; other services
reach it via the `baseurls_async_tasks` group var (e.g.
[apps](/services/apps.md) sets `apps.async-tasks.base-url` from it). Its
configuration is the shared job-services config: the role templates
`jobservices.yml.j2`, which carries connection details for
[RabbitMQ](/infrastructure/rabbitmq.md) (exchange `de`), the DE and
notifications databases on [PostgreSQL](/infrastructure/postgresql.md),
[iRODS](/infrastructure/irods.md), [Keycloak](/infrastructure/keycloak.md),
[Harbor](/infrastructure/harbor.md) robot credentials, a
[Condor](/infrastructure/condor.md) section, and base URLs for
[apps](/services/apps.md), [metadata](/services/metadata.md),
[notifications](/services/notifications.md),
[iplant-groups](/services/iplant-groups.md), [qms](/services/qms.md),
[job-status-listener](/services/job-status-listener.md), and VICE settings.
The same template content appears in the app-exposer role; async-tasks reads
whichever subsections it needs from the shared shape.

## Source and image

- Source repo: [cyverse-de/async-tasks](https://github.com/cyverse-de/async-tasks).
- Image: `harbor.cyverse.org/de/async-tasks`, pinned in `files/async-tasks.json`.

## Configuration and runtime

The rendered config lands in the `async-tasks-configs` secret, mounted at
`/etc/iplant/de/jobservices.yml` and passed with `--config`. The pod reads
OTEL settings from the `configs` secret for
[Jaeger](/infrastructure/jaeger.md). Defaults: `async_tasks_replicas: 2` with
pod anti-affinity; listen port 60000 behind a ClusterIP service on port 80.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags async-tasks
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/async-tasks/templates/jobservices.yml.j2` — shared job-services config template.
2. `ansible/roles/services/async-tasks/tasks/main.yml` — creates the `async-tasks-configs` secret and includes `deploy-service`.
3. `ansible/roles/services/async-tasks/templates/k8s/async-tasks.yml.j2` — deployment; `--config /etc/iplant/de/jobservices.yml`, OTEL env.
4. `ansible/roles/services/async-tasks/files/async-tasks.json` — build descriptor pinning the image.
5. `ansible/roles/services/apps/templates/apps.properties.j2` — consumer of `baseurls_async_tasks`.
