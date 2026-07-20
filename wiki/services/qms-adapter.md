---
type: Service
title: qms-adapter
description: Adapter that bridges the DE AMQP exchange and QMS, forwarding usage updates to the QMS admin usages endpoint.
resource: /ansible/roles/services/qms-adapter
tags: [qms, adapter, amqp, usage, quotas]
timestamp: 2026-07-20T00:00:00Z
---

An adapter between the DE messaging layer and [qms](/services/qms.md). Its
configuration contains the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic
exchange URI (`de_amqp_*` vars) and a `qms` section pointing at
`baseurls_qms` with the `/v1/admin/usages` endpoint (gated by `qms_enabled`),
so it forwards usage updates arriving over AMQP to QMS. The source repo is
[cyverse-de/qms-adapter](https://github.com/cyverse-de/qms-adapter) and the
image is `harbor.cyverse.org/de/qms-adapter`, pinned in
`ansible/roles/services/qms-adapter/files/qms-adapter.json`.

Configuration: the role renders the shared DE jobservices template
(`templates/jobservices.yml.j2`) into the `qms-adapter-configs` secret
(skipped when `load_configs` is false), mounted at
`/etc/iplant/de/jobservices.yml`. Besides the AMQP and QMS sections, the
shared template carries [PostgreSQL](/infrastructure/postgresql.md) URIs for
the DE and notifications databases and base URLs for other DE services;
notable group_vars are `de_amqp_*`, `baseurls_qms`, `qms_enabled`,
`dbms_connection_user`/`dbms_connection_pass`, and `de_db_name`.

Runtime: a Deployment with `qms_adapter_replicas` (default 2) and optional pod
anti-affinity, run with `--log-level debug`, listening on port 60000 behind a
`qms-adapter` Service on port 80. OpenTelemetry tracing goes to
[Jaeger](/infrastructure/jaeger.md) via the shared `configs` secret. The
manifest defines no HTTP health probes.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags qms-adapter`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/qms-adapter/templates/jobservices.yml.j2` — AMQP URI and qms usage endpoint config.
[2] `ansible/roles/services/qms-adapter/templates/k8s/qms-adapter.yml.j2` — Deployment, Service, args, OTEL env.
[3] `ansible/roles/services/qms-adapter/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/qms-adapter/files/qms-adapter.json` — pinned image.
