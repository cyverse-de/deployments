---
type: Service
title: event-recorder
description: AMQP worker that consumes event messages from the de exchange and records them, sharing the jobservices.yml configuration with the other jobservices workers.
resource: /ansible/roles/services/event-recorder
tags: [event-recorder, amqp, rabbitmq, jobservices, events]
timestamp: 2026-07-20T00:00:00Z
---

event-recorder is another of the Go "jobservices" workers: a headless consumer
(no Service, no ports) attached to the `de` topic exchange on the DE
[RabbitMQ](/infrastructure/rabbitmq.md) broker. Its configuration gives it
connections to the `de` and `notifications`
[PostgreSQL](/infrastructure/postgresql.md) databases, which is where events it
picks up off the exchange end up being recorded.

Source repo: [cyverse-de/event-recorder](https://github.com/cyverse-de/event-recorder);
image `harbor.cyverse.org/de/event-recorder` (`v2026.06.02` pinned by digest in
the build descriptor) on [Harbor](/infrastructure/harbor.md).

## Configuration

Like [email-requests](/services/email-requests.md), the role renders the shared
`jobservices.yml.j2` template into a Secret (`event-recorder-configs`) mounted
at `/etc/iplant/de/jobservices.yml` and passed with `--config`. The template is
the family-wide config — AMQP URI and prefetch settings, database URIs
(`de_db_name`, `notifications_db_name`), [iRODS](/infrastructure/irods.md)
credentials, and base URLs for [apps](/services/apps.md),
[notifications](/services/notifications.md),
[metadata](/services/metadata.md), and more — of which each worker reads its
own subset. `-e load_configs=false` skips regenerating the Secret.

## Deploying

The Deployment runs `event_recorder_replicas` (default 2) lightweight pods
(100m CPU / 256Mi limits) with OpenTelemetry traces exported to
[Jaeger](/infrastructure/jaeger.md). Deploy per
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags event-recorder
```

# Citations

1. `ansible/roles/services/event-recorder/files/event-recorder.json` — build descriptor with image name and pinned tag/digest.
2. `ansible/roles/services/event-recorder/templates/jobservices.yml.j2` — shared jobservices config: AMQP, DE/notifications DB URIs, service base URLs.
3. `ansible/roles/services/event-recorder/tasks/main.yml` — creates the `event-recorder-configs` Secret and includes deploy-service.
4. `ansible/roles/services/event-recorder/templates/k8s/event-recorder.yml.j2` — Deployment spec: replicas, resources, `--config` arg, OTEL env.
5. `ansible/roles/services/event-recorder/defaults/main.yml` — `event_recorder_replicas: 2`.
6. `ansible/deploy_it.yml` — role wired in under the `event-recorder` tag.
