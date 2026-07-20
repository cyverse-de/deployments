---
type: Service
title: dewey
description: Indexes data-store changes into OpenSearch by consuming iRODS change messages from the irods AMQP exchange.
resource: /ansible/roles/services/dewey
tags: [indexing, search, irods, opensearch, amqp, de]
timestamp: 2026-07-20T00:00:00Z
---

dewey keeps the data-store search index up to date. It is a JVM service (the
pod sets `JAVA_TOOL_OPTIONS`) that consumes change messages from the `irods`
exchange on the iRODS-side [RabbitMQ](/infrastructure/rabbitmq.md) broker
(`irods_amqp_*`, queue `dewey.indexing`, QoS 100) and writes documents to
[OpenSearch](/infrastructure/opensearch.md) (`es_base_uri`/`es_index`). It
also holds a second AMQP connection to the DE broker (`de_amqp_*`) for events,
and connects to [iRODS](/infrastructure/irods.md) itself as `irods_user` to
read the data being indexed.

- Source: [cyverse-de/dewey](https://github.com/cyverse-de/dewey); image `harbor.cyverse.org/de/dewey` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `dewey.properties.j2` is templated into the `dewey-configs` secret and mounted at `/etc/iplant/de/dewey.properties`. Notable vars: `irods_amqp_*`, `de_amqp_*`, `es_base_uri`, `es_username`/`es_password`, `es_index`, `irods_*`.
- Runtime: 2 replicas by default (`dewey_replicas`, no anti-affinity setting in this role); listens on port 60000 behind a ClusterIP Service on port 80, with startup/liveness/readiness probes on `/`.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags dewey` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/dewey/templates/dewey.properties.j2` — irods/de AMQP URIs, queue name, OpenSearch and iRODS settings.
2. `ansible/roles/services/dewey/files/dewey.json` — pinned image name and digest.
3. `ansible/roles/services/dewey/templates/k8s/dewey.yml.j2` — Deployment/Service, port 60000, JAVA_TOOL_OPTIONS, probes.
4. `ansible/roles/services/dewey/tasks/main.yml` — creates the `dewey-configs` secret, then runs deploy-service.
5. `ansible/roles/common/defaults/main.yml` — `es_base_uri`/`es_index` and `irods_amqp_*` defaults.
