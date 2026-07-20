---
type: Service
title: email-requests
description: AMQP worker that consumes email request messages from the de exchange and hands them to iplant-email for delivery, configured from the shared jobservices.yml template.
resource: /ansible/roles/services/email-requests
tags: [email-requests, amqp, rabbitmq, jobservices, notifications]
timestamp: 2026-07-20T00:00:00Z
---

email-requests is one of the Go "jobservices" workers. It has no Kubernetes
Service and no listen port — it is a pure consumer on the `de` topic exchange of
the DE [RabbitMQ](/infrastructure/rabbitmq.md) broker
(`de_amqp_user`/`de_amqp_host`/`de_amqp_vhost`). Its configuration points it at
the iplant-email base URL (`baseurls_iplant_email`) and the support address
(`email_support_dest`), so its job is turning email-request messages published
on the exchange into outbound mail.

Source repo: [cyverse-de/email-requests](https://github.com/cyverse-de/email-requests);
image `harbor.cyverse.org/de/email-requests` (pinned by digest in the build
descriptor, `v2025.08.05` as of this writing) on [Harbor](/infrastructure/harbor.md).

## Configuration

The role renders `templates/jobservices.yml.j2` — the large config file shared
by the jobservices family — into the `email-requests-configs` Secret and mounts
it at `/etc/iplant/de/jobservices.yml` (passed via `--config`). The template
covers far more than this service uses: AMQP, the `de` and `notifications`
[PostgreSQL](/infrastructure/postgresql.md) databases
(`dbms_connection_user`, `de_db_name`, `notifications_db_name`),
[iRODS](/infrastructure/irods.md) credentials, and base URLs for
[apps](/services/apps.md), [metadata](/services/metadata.md),
[notifications](/services/notifications.md),
[iplant-groups](/services/iplant-groups.md), and VICE/Keycloak settings.
Skipping the Secret refresh is possible with `-e load_configs=false`.

## Deploying

The Deployment runs `email_requests_replicas` (default 2) small pods (100m
CPU / 256Mi limits) with OpenTelemetry tracing exported to
[Jaeger](/infrastructure/jaeger.md). Deploy with the usual flow — see
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags email-requests
```

# Citations

1. `ansible/roles/services/email-requests/files/email-requests.json` — build descriptor with image name and pinned tag/digest.
2. `ansible/roles/services/email-requests/templates/jobservices.yml.j2` — shared jobservices config: AMQP URI, DB URIs, iplant-email and other service base URLs.
3. `ansible/roles/services/email-requests/tasks/main.yml` — creates the `email-requests-configs` Secret and includes the deploy-service role.
4. `ansible/roles/services/email-requests/templates/k8s/email-requests.yml.j2` — Deployment: replicas, resources, `--config` arg, OTEL env vars.
5. `ansible/roles/services/email-requests/defaults/main.yml` — `email_requests_replicas: 2`.
6. `ansible/deploy_it.yml` — wires the role in under the `email-requests` tag.
