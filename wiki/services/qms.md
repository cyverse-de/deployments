---
type: Service
title: qms
description: The Quota Management Service, tracking subscription plans and resource usage in its own PostgreSQL database.
resource: /ansible/roles/services/qms
tags: [qms, quotas, subscriptions, postgresql, amqp]
timestamp: 2026-07-23T00:00:00Z
---

The Quota Management Service (QMS). Unusually among DE services, its source
repo lives in the `cyverse` GitHub org rather than `cyverse-de`:
[cyverse/qms](https://github.com/cyverse/qms) (see the `source_repo_urls`
override in `ansible/roles/common/defaults/main.yml`). The image is
`harbor.cyverse.org/de/qms`, pinned in
`ansible/roles/services/qms/files/qms.json`.

Its primary database connection comes from env vars drawn from the shared
`configs` secret: `QMS_DATABASE_URI`, plus `QMS_DATABASE_MIGRATE` and
`QMS_DATABASE_REINIT` to control schema migration on startup, and
`QMS_USERNAME_SUFFIX` (from `USERNAME_SUFFIX`). It also mounts the shared DE
jobservices config, rendered from `templates/jobservices.yml.j2` into the
`qms-configs` secret and mounted as `/etc/cyverse/de/configs/service.yml`;
that template carries the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic
exchange URI (`de_amqp_*` vars), [PostgreSQL](/infrastructure/postgresql.md)
URIs, and DE service base URLs among its many shared settings.

Runtime: a Deployment with `qms_replicas` (default 2), optional pod
anti-affinity, and the `configurator` service account, listening on port 9000
behind a `qms` Service on port 80. OpenTelemetry tracing goes to
[Jaeger](/infrastructure/jaeger.md). Other services reach its usage endpoint
via `baseurls_qms`.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags qms`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/qms/templates/k8s/qms.yml.j2` — QMS_DATABASE_* env, service account, ports.
[2] `ansible/roles/services/qms/templates/jobservices.yml.j2` — shared jobservices config contents.
[3] `ansible/roles/services/qms/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/qms/files/qms.json` — pinned image.
[5] `ansible/roles/common/defaults/main.yml` — `source_repo_urls` override pointing qms at the cyverse org.
