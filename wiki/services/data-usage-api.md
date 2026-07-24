---
type: Service
title: data-usage-api
description: Reports per-user data-store usage by querying the ICAT database, serving results over HTTP.
resource: /ansible/roles/services/data-usage-api
tags: [data, usage, quotas, icat, de]
timestamp: 2026-07-24T00:00:00Z
---

data-usage-api computes data-store usage numbers. Its config gives it two
[PostgreSQL](/infrastructure/postgresql.md) connections — the DE database and
the ICAT database — with the ICAT side scoped to the root resources in
`irods_quota_root_resources` (default `mainIngestRes,mainReplRes`) for the
zone `irods_zone`. It also connects to the DE
[RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange, and it reads and
records QMS usage by calling [subscriptions](/services/subscriptions.md) over
HTTP at `--subscriptions-base-uri` (`baseurls_subscriptions`, default
`http://subscriptions`). Usernames are qualified with `uid_domain`.

- Source: [cyverse-de/data-usage-api](https://github.com/cyverse-de/data-usage-api); image `harbor.cyverse.org/de/data-usage-api` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `data-usage-api.yml.j2` is templated into the `data-usage-api-configs` secret and mounted at `/etc/iplant/de/data-usage-api.yml`. Notable vars: `dbms_connection_*`, `icat_*`, `irods_quota_root_resources`, `de_amqp_*`, `uid_domain`.
- Runtime: 2 replicas by default (`data_usage_api_replicas`) with required pod anti-affinity; runs under the `configurator` service account; listens on port 60000 behind a ClusterIP Service on port 80.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags
data-usage-api` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/data-usage-api/templates/data-usage-api.yml.j2` — DE/ICAT DB URIs, root resources, AMQP exchange, uid domain.
2. `ansible/roles/services/data-usage-api/files/data-usage-api.json` — pinned image name and digest.
3. `ansible/roles/services/data-usage-api/templates/k8s/data-usage-api.yml.j2` — `--subscriptions-base-uri` arg, service account, probes.
4. `ansible/roles/services/data-usage-api/tasks/main.yml` — creates the `data-usage-api-configs` secret, then runs deploy-service.
5. `ansible/roles/common/defaults/main.yml` — `irods_quota_root_resources` default.
