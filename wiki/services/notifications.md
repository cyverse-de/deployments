---
type: Service
title: notifications
description: User notifications service backed by its own notifications database, reached by other services at http://notifications/v1.
resource: /ansible/roles/services/notifications
tags: [notifications, postgresql, amqp, jobservices]
timestamp: 2026-07-20T00:00:00Z
---

notifications stores and serves DE user notifications. Its config points at a
dedicated database — `notifications_db_name` (default `notifications`) on the
[PostgreSQL](/infrastructure/postgresql.md) DBMS host — alongside the DE
database and the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange.
It listens on port 8080, exposed in-cluster as Service `notifications` on
port 80; other services reach it via `baseurls_notifications`
(`http://notifications/v1`), which the shared job-services template exposes to
its consumers as `notification_agent.base`. OpenTelemetry tracing is
explicitly disabled for this service (`OTEL_TRACES_EXPORTER=none` is hardcoded
in the manifest).

- **Source repo:** [cyverse-de/notifications](https://github.com/cyverse-de/notifications)
- **Image:** `harbor.cyverse.org/de/notifications` (pinned in
  `files/notifications.json`)

## Configuration

The role renders the shared job-services template
`templates/jobservices.yml.j2` into the `notifications-configs` secret,
mounted at `/etc/iplant/de/jobservices.yml`. The operative section is
`notifications.db.uri`, built from `dbms_connection_user`/
`dbms_connection_pass`, `groups['dbms'][0]`, `pg_listen_port`, and
`notifications_db_name`; the AMQP URI comes from the `de_amqp_*` group_vars.
The rest of the shared template (Condor, iRODS, VICE, Keycloak, Harbor) is
common boilerplate across the job services. Defaults:
`notifications_replicas: 2` with required pod anti-affinity.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags notifications
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/notifications/templates/jobservices.yml.j2` — notifications DB URI and AMQP configuration.
2. `ansible/roles/services/notifications/templates/k8s/notifications.yml.j2` — Deployment/Service, port 8080, `OTEL_TRACES_EXPORTER=none`.
3. `ansible/roles/services/notifications/files/notifications.json` — image and pinned tag/digest.
4. `ansible/roles/common/defaults/main.yml` — `notifications_db_name`, `baseurls_notifications`, `source_repos` entry.
