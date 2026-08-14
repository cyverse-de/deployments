---
type: Service
title: notifications
description: User notifications service backed by its own notifications database, reached by other services at http://notifications/v1; also records the notification events it publishes and sends the resulting email, roles absorbed from the retired event-recorder and de-mailer.
resource: /ansible/roles/services/notifications
tags: [notifications, postgresql, amqp, rabbitmq, jobservices, events, email, smtp]
timestamp: 2026-08-14T00:00:00Z
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

That dedicated database is on its way out. `de-database` migrations `000055`
and `000056` create `public.notifications` in the DE database, and
[Merging the Notifications Database into DE](/playbooks/notifications-db-merge.md)
moves the rows.

The service change that goes with it is username qualification, and it ships
in the same deploy as the repoint rather than ahead of it — against the
standalone database, whose `users` rows are bare, a qualifying service would
create a second row per person and their existing notifications would drop out
of their list. Callers
send bare usernames — apps and terrain both pass `shortUsername` — while the DE
identifies users by the qualified form, so the service now appends
`notifications.uid.domain` (rendered from `uid_domain`) before any user lookup.
It truncates at the first `@` first, matching `apps.user/append-username-suffix`,
so an account already named as an address resolves to the same DE user every
other service resolves it to. The setting is required and validated at startup.

Qualification happens only on the way to the database. The username in
`outgoing_json` and in the `notification.<user>` message stays exactly as the
caller sent it, because clients read it back out.

## Event recording

As of the 2026-08 merge, this service also records the notification events it
publishes — the job the standalone event-recorder used to do. `POST
/v1/notification` validates a request and publishes it to the `de` topic
exchange on the [RabbitMQ](/infrastructure/rabbitmq.md) broker with the
`events.notification.update.<type>` routing key; an in-process consumer reads
the durable `event_listener` queue (binding `events.*.update.*`), writes the
notification to the notifications database, and publishes both the outgoing
email request on `email.requests` — which this same service consumes, see
[Email delivery](#email-delivery) — and the `notification.<user>` message the
DE UI listens for. The queue sits between the two halves so a caller's POST
returns once the event is published rather than waiting on the database write.

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

## Email delivery

As of the 2026-08 merge, this service also sends the DE's outbound email — the
job the standalone de-mailer used to do. Requests reach it two ways: other
services POST to it via `baseurls_iplant_email`, which now points at
`http://notifications/mail` (terrain, apps, and requests use this path), and
it consumes email-request messages from the durable `email_requests` queue
(routing key `email.requests`) on the `de` topic exchange. The event recorder
above is the only publisher on that routing key.

The hop through the broker is deliberate. Short-circuiting the recorder
straight into the mail sender would have sent every notification email twice
for the length of a rollout, because the retired de-mailer's pods keep
draining `email_requests` until they are scaled down; as competing consumers
on one queue instead, each request is sent once. It also keeps the queue's
buffering across an SMTP outage. As with event-recorder, that makes the
cutover safe in one direction only: deploy notifications first and confirm it
is sending, then scale de-mailer down. This role removes the orphaned
`de-mailer` Deployment, Service, and `de-mailer-configs` secret; those tasks
can go once every deployment has rolled past this release.

Message bodies are rendered from templates shipped in the image under
`/app/templates/{html,text}`, selected by the request's template name and
preferring the HTML version. The merge added the `de:` config block (the DE
base URL plus the UI path fragments used to build links in email bodies) and
two settings under `email:` — `fromAddress` (`email_src`) and `smtpHost`
(hardcoded to `local-exim`). All of `email.fromAddress`, `email.smtpHost`, and
`de.base` are validated at startup alongside the existing required settings,
so a missing one fails the deployment rather than failing every send.

Failed AMQP deliveries are logged with their cause and acked (dropped),
matching the retired service's behavior. On `SIGTERM` the service drains
in-flight deliveries before closing the connection, so mail that was already
sent isn't requeued and sent again on the next rolling deploy.

### The local-exim relay

local-exim is an Exim relay deployed into the DE namespace by the
`k8s_de_reqs` role, or on its own with `local-exim.yml` (see
[Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md)).

It is configured entirely from `exim_*` inventory variables, and their role
defaults are non-functional placeholders rather than sane fallbacks:
`exim_smarthost` defaults to loopback, which points exim at itself, and
`exim_allowed_senders` defaults to the Docker bridge network. The relay nets
are safe — the role prepends `k8s_pods_cidr` and `k8s_services_cidr` — but the
smarthost is not, so an environment that never set `exim_smarthost` accepts
mail from notifications and then fails to route it. Set `exim_smarthost` to
the real upstream relay in the inventory; `local-exim.yml` asserts this before
applying.

`exim_smarthost` is an exim host list, not a `host:port` pair: a single colon
separates hosts, so a port needs a second one (`mailgate.cyverse.org::25`).
`host:25` parses as two hosts and appends a bogus one named `25`, which exim
resolves to `0.0.0.25`. Mail still flows, since the real relay is tried first
on its default port, but a failover then stalls on the bogus host instead of
deferring cleanly.

The relay pods are not on `hostNetwork`, so they reach the upstream smarthost
SNAT'd as their node's IP — the smarthost's relay allowlist has to cover the
cluster nodes, and the Deployment has no node selector, so any node can end up
running one.

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
The `de:` and `email:` blocks drive outbound mail. The rest of the shared
template (Condor, iRODS, VICE, Keycloak, Harbor) is common boilerplate across
the job services. Defaults: `notifications_replicas: 2` with required pod
anti-affinity.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags notifications
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/notifications/templates/jobservices.yml.j2` — notifications DB URI, AMQP configuration, `email.request`, and the `de:`/`email:` blocks that drive outbound mail.
2. `ansible/roles/services/notifications/templates/k8s/notifications.yml.j2` — Deployment/Service, port 8080, `OTEL_TRACES_EXPORTER=none`.
3. `ansible/roles/services/notifications/files/notifications.json` — image and pinned tag/digest.
4. `ansible/roles/common/defaults/main.yml` — `notifications_db_name`, `baseurls_notifications`, `baseurls_iplant_email`, `email_support_dest`, `email_src`, `source_repos` entry, and the placeholder `exim_*` defaults.
5. `ansible/roles/services/notifications/tasks/main.yml` — creates the `notifications-configs` Secret and removes the retired event-recorder and de-mailer objects.
6. `ansible/roles/k8s_de_reqs/tasks/local_exim.yml` — the local-exim Deployment and Service, and how `EXIM_ALLOWED_SENDERS` is assembled from the cluster CIDRs.
7. `ansible/local-exim.yml` — standalone local-exim run with the smarthost assertion.
