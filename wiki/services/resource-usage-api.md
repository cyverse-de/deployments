---
type: Service
title: resource-usage-api
description: HTTP API for DE resource usage data, backed by the DE database and the subscriptions service.
resource: /ansible/roles/services/resource-usage-api
tags: [resource-usage, postgresql, usage, http]
timestamp: 2026-07-24T00:00:00Z
---

An HTTP API over DE resource usage data. It consumes analysis status events
from [RabbitMQ](/infrastructure/rabbitmq.md), computes CPU hours per analysis,
and records them against QMS by calling
[subscriptions](/services/subscriptions.md) over HTTP at
`--subscriptions-base-uri` (`baseurls_subscriptions`, default
`http://subscriptions`) — the same base URL its `/summary` handler uses. The
source repo is
[cyverse-de/resource-usage-api](https://github.com/cyverse-de/resource-usage-api)
and the image is `harbor.cyverse.org/de/resource-usage-api`, pinned in
`ansible/roles/services/resource-usage-api/files/resource-usage-api.json`.

Configuration: the role renders the shared DE jobservices template
(`templates/jobservices.yml.j2`) into the `resource-usage-api-configs` secret
(skipped when `load_configs` is false), mounted as
`/etc/cyverse/de/configs/service.yml`. Relevant pieces of that shared config
include the DE and notifications database URIs on
[PostgreSQL](/infrastructure/postgresql.md)
(`dbms_connection_user`/`dbms_connection_pass`, `de_db_name`,
`notifications_db_name`), the [RabbitMQ](/infrastructure/rabbitmq.md) `de`
exchange URI (`de_amqp_*`), the `qms` section (`baseurls_qms`,
`qms_enabled`), and `users.domain` (`uid_domain`).

Runtime: a Deployment with `resource_usage_api_replicas` (default 2), optional
pod anti-affinity, and the `configurator` service account, run with
`--log-level debug` and `--subscriptions-base-uri`, listening on port 60000
behind a `resource-usage-api`
Service on port 80, with probes on `/`. OpenTelemetry tracing goes to
[Jaeger](/infrastructure/jaeger.md).

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags resource-usage-api`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/resource-usage-api/templates/k8s/resource-usage-api.yml.j2` — `--subscriptions-base-uri` arg, env, ports, service account.
[2] `ansible/roles/services/resource-usage-api/templates/jobservices.yml.j2` — shared config: DB URIs, AMQP, qms section.
[3] `ansible/roles/services/resource-usage-api/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/resource-usage-api/files/resource-usage-api.json` — pinned image.
