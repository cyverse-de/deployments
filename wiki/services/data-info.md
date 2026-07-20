---
type: Service
title: data-info
description: HTTP API for data-store operations — file and folder metadata, permissions, path lists, and anonymous-access URLs backed by iRODS.
resource: /ansible/roles/services/data-info
tags: [data, irods, icat, files, de]
timestamp: 2026-07-20T00:00:00Z
---

data-info is the DE's data-store API. It is a JVM service (the pod sets
`JAVA_TOOL_OPTIONS`) that talks directly to [iRODS](/infrastructure/irods.md)
as `irods_user` and queries the ICAT [PostgreSQL](/infrastructure/postgresql.md)
database (`icat_host`/`ICAT`). It builds anonymous-access URLs against the
iRODS WebDAV `dav-anon` endpoint (`irods_webdav_anon_uri`, with a fallback to
`{{ de_base_uri }}/anon-files`) and [kifshare](/services/kifshare.md)-style
download links under `{{ de_base_uri }}/dl`. It calls the
[async-tasks](/services/async-tasks.md), [notifications](/services/notifications.md),
and [metadata](/services/metadata.md) services, and connects to the DE
[RabbitMQ](/infrastructure/rabbitmq.md) vhost via `de_amqp_*`.

- Source: [cyverse-de/data-info](https://github.com/cyverse-de/data-info); image `harbor.cyverse.org/de/data-info` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `data-info.properties.j2` is templated into the `data-info-configs` secret and mounted at `/etc/iplant/de/data-info.properties`. Notable vars: `irods_*` (host, zone, admin users, perms filter), `icat_*`, `de_amqp_*`, `baseurls_*`, `de_base_uri`.
- Runtime: 2 replicas by default (`data_info_replicas`) with required pod anti-affinity; listens on port 60000; OpenTelemetry tracing to [Jaeger](/infrastructure/jaeger.md) is wired via the `configs` secret.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags data-info` —
see [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/data-info/templates/data-info.properties.j2` — iRODS/ICAT/AMQP config, anon-files mappings, dependent service URLs.
2. `ansible/roles/services/data-info/files/data-info.json` — pinned image name and digest.
3. `ansible/roles/services/data-info/templates/k8s/data-info.yml.j2` — Deployment/Service, port 60000, JAVA_TOOL_OPTIONS, OTEL env.
4. `ansible/roles/services/data-info/tasks/main.yml` — creates the `data-info-configs` secret, then runs deploy-service.
