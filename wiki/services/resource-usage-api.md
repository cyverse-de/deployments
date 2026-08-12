---
type: Service
title: resource-usage-api
description: HTTP API for DE resource usage data — CPU hours from the DE database and data-store usage from the ICAT database.
resource: /ansible/roles/services/resource-usage-api
tags: [resource-usage, data-usage, postgresql, icat, usage, http]
timestamp: 2026-08-12T00:00:00Z
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

It also computes per-user data-store usage by querying the iRODS ICAT
database, work that belonged to the separate data-usage-api service until that
service was merged into this one. The data usage routes kept their paths, so
[terrain](/services/terrain.md) needed only a new base URI.

Endpoints:

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Greeting, used as the liveness and readiness probe |
| `GET` | `/summary/:username` | CPU usage, data usage, and subscription for a user |
| `GET` | `/:username/data/current` | The user's data usage as recorded in QMS |
| `POST` | `/:username/data/update` | Recompute data usage from ICAT and record it |
| `GET` | `/:username/data/overage` | Whether the user is over their data quota |

`/:username/data/current` answers `404` when QMS holds no reading yet, and
enqueues a refresh at the same time, so a later request finds one.

It consumes three queues on the `de` exchange: `resource-usage-api` for
analysis status updates, and `data-usage-api.batch` and
`data-usage-api.individual` for data usage refreshes. The two data usage queue
names are inherited from the merged service so its durable queues carry over,
and take a prefix from `resource_usage_api_queue_prefix`.

Configuration: the role renders the shared DE jobservices template
(`templates/jobservices.yml.j2`) into the `resource-usage-api-configs` secret
(skipped when `load_configs` is false), mounted as
`/etc/cyverse/de/configs/service.yml`. Relevant pieces of that shared config
include the DE and notifications database URIs on
[PostgreSQL](/infrastructure/postgresql.md)
(`dbms_connection_user`/`dbms_connection_pass`, `de_db_name`,
`notifications_db_name`), the ICAT database URI, zone, and root resources
(`icat_*`, `irods_zone`, `irods_quota_root_resources`), the
[RabbitMQ](/infrastructure/rabbitmq.md) `de` exchange URI (`de_amqp_*`), the
`qms` section (just `qms_enabled`, which despite the name selects between two
subscriptions-backed summarizers), and `users.domain` (`uid_domain`).

The service validates its configuration at startup and exits if anything
required is missing, so the config secret has to be in place before the pod
rolls. Note that `icat.uri` puts the ICAT database password in this secret.

Runtime: a Deployment with `resource_usage_api_replicas` (default 2), optional
pod anti-affinity, and the `configurator` service account, run with
`--log-level debug` and `--subscriptions-base-uri`, listening on port 60000
behind a `resource-usage-api` Service on port 80, with probes on `/`. The pod
holds two database pools and runs data usage batches alongside the
latency-sensitive summary endpoint, so its CPU limit is 500m rather than the
100m most services get. A batch can hold the ICAT database for minutes and the
service drains in-flight work on `SIGTERM`, so
`resource_usage_api_termination_grace_period` (default 330s) gives it room to
finish.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags resource-usage-api`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/resource-usage-api/templates/k8s/resource-usage-api.yml.j2` — `--subscriptions-base-uri` arg, env, ports, service account, resource limits, grace period.
[2] `ansible/roles/services/resource-usage-api/templates/jobservices.yml.j2` — shared config: DB and ICAT URIs, AMQP, data usage settings, qms section.
[3] `ansible/roles/services/resource-usage-api/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/resource-usage-api/files/resource-usage-api.json` — pinned image.
[5] `ansible/roles/services/resource-usage-api/defaults/main.yml` — replicas, anti-affinity, data usage settings, grace period.
