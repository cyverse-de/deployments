---
type: Service
title: requests
description: HTTP service for administrative requests in the DE, backed by the DE database via the shared jobservices configuration.
resource: /ansible/roles/services/requests
tags: [requests, administrative, postgresql, http]
timestamp: 2026-07-20T00:00:00Z
---

The DE requests service, an HTTP API for administrative requests. The source
repo is [cyverse-de/requests](https://github.com/cyverse-de/requests) and the
image is `harbor.cyverse.org/de/requests`, pinned in
`ansible/roles/services/requests/files/requests.json`.

Configuration: the role renders the shared DE jobservices template
(`templates/jobservices.yml.j2`) into the `requests-configs` secret (skipped
when `load_configs` is false), mounted at `/etc/iplant/de/jobservices.yml`
and passed via `--config`. The shared template is a grab-bag used by several
services; the pieces available to this one include the DE database URI on
[PostgreSQL](/infrastructure/postgresql.md)
(`dbms_connection_user`/`dbms_connection_pass`, `de_db_name`), the
notifications database URI, the [RabbitMQ](/infrastructure/rabbitmq.md) `de`
exchange URI (`de_amqp_*`), and base URLs for other DE services such as
iplant-groups, notifications, and iplant-email (`baseurls_*` vars).

Runtime: a Deployment with `requests_replicas` (default 2) and optional pod
anti-affinity, listening on port 8080 behind a `requests` Service on port 80,
with liveness/readiness probes on `/`. OpenTelemetry tracing goes to
[Jaeger](/infrastructure/jaeger.md) via `OTEL_*` env vars from the shared
`configs` secret.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags requests`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/requests/templates/jobservices.yml.j2` — shared config: DB URIs, AMQP, service base URLs.
[2] `ansible/roles/services/requests/templates/k8s/requests.yml.j2` — Deployment, Service, port 8080, probes.
[3] `ansible/roles/services/requests/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/requests/files/requests.json` — pinned image.
