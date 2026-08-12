---
type: Service
title: notifications
description: User notifications service backed by its own notifications database, reached by other services at http://notifications/v1; also records the notification events it publishes, a role absorbed from the retired event-recorder.
resource: /ansible/roles/services/notifications
tags: [notifications, postgresql, amqp, rabbitmq, jobservices, events]
timestamp: 2026-08-12T00:00:00Z
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

## Event recording

As of the 2026-08 merge, this service also records the notification events it
publishes — the job the standalone event-recorder used to do. `POST
/v1/notification` validates a request and publishes it to the `de` topic
exchange on the [RabbitMQ](/infrastructure/rabbitmq.md) broker with the
`events.notification.update.<type>` routing key; an in-process consumer reads
the durable `event_listener` queue (binding `events.*.update.*`), writes the
notification to the notifications database, and publishes both the outgoing
email request on `email.requests` — which
[de-mailer](/services/de-mailer.md) consumes — and the `notification.<user>`
message the DE UI listens for. The queue sits between the two halves so a
caller's POST returns once the event is published rather than waiting on the
database write.

The queue name and binding deliberately match what event-recorder used, so
during a rollout both act as competing consumers on the same queue instead of
each building their own. That makes the cutover safe in one direction only:
deploy notifications first and confirm it is recording, then scale
event-recorder down. Removing the event-recorder role from this repo did not
delete its running objects, so this role also removes the orphaned
`event-recorder` Deployment and `event-recorder-configs` secret; those tasks
can go once every deployment has rolled past this release.

The merge added one required setting, `email.request` (`email_support_dest`) —
the address that receives a notice when a delivery is discarded because it
could not be recorded. The service validates its required settings at startup
and refuses to start if any is missing, so an unset value fails the deployment
rather than silently sending those notices nowhere. The shared job-services
template already rendered it.

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

1. `ansible/roles/services/notifications/templates/jobservices.yml.j2` — notifications DB URI, AMQP configuration, and `email.request`.
2. `ansible/roles/services/notifications/templates/k8s/notifications.yml.j2` — Deployment/Service, port 8080, `OTEL_TRACES_EXPORTER=none`.
3. `ansible/roles/services/notifications/files/notifications.json` — image and pinned tag/digest.
4. `ansible/roles/common/defaults/main.yml` — `notifications_db_name`, `baseurls_notifications`, `email_support_dest`, `source_repos` entry.
5. `ansible/roles/services/notifications/tasks/main.yml` — creates the `notifications-configs` Secret and removes the retired event-recorder Deployment and secret.
