---
type: Service
title: de-webhooks
description: Consumes DE notification messages from RabbitMQ and forwards them to users' configured webhook endpoints.
resource: /ansible/roles/services/de-webhooks
tags: [webhooks, notifications, amqp, de]
timestamp: 2026-07-20T00:00:00Z
---

de-webhooks is a message consumer, not an HTTP API: its config binds it to the
`de` topic exchange on the DE [RabbitMQ](/infrastructure/rabbitmq.md) vhost
with routing key `notification.*`, and it connects to the DE
[PostgreSQL](/infrastructure/postgresql.md) database (where users' webhook
subscriptions live). It also gets the DE base URL for building links and a
fixed user suffix of `iplantcollaborative.org`.

- Source: [cyverse-de/de-webhooks](https://github.com/cyverse-de/de-webhooks); image `harbor.cyverse.org/de/de-webhooks` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `webhooks.yml.j2` is templated into the `de-webhooks-configs` secret and mounted at `/etc/iplant/de/webhooks.yml`. Notable vars: `de_amqp_*`, `dbms_connection_*`, `de_db_name`, `de_base_uri`.
- Runtime: 2 replicas by default (`de_webhooks_replicas`) with required pod anti-affinity. The manifest defines only a Deployment — no Kubernetes Service, no ports, and no probes — consistent with a pure queue consumer. OpenTelemetry tracing to [Jaeger](/infrastructure/jaeger.md) is wired via the `configs` secret.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags de-webhooks`
— see [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/de-webhooks/templates/webhooks.yml.j2` — AMQP exchange/routing key, DE DB URI, user suffix.
2. `ansible/roles/services/de-webhooks/files/de-webhooks.json` — pinned image name and digest.
3. `ansible/roles/services/de-webhooks/templates/k8s/de-webhooks.yml.j2` — Deployment only, no Service or probes.
4. `ansible/roles/services/de-webhooks/tasks/main.yml` — creates the `de-webhooks-configs` secret, then runs deploy-service.
