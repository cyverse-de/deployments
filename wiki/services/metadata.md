---
type: Service
title: metadata
description: DE metadata service backed by its own metadata database on PostgreSQL.
resource: /ansible/roles/services/metadata
tags: [metadata, postgresql, amqp, jvm]
timestamp: 2026-07-20T00:00:00Z
---

metadata is the DE's metadata service. It owns a dedicated database — its
config connects to `metadata_db_name` (default `metadata`) on the
[PostgreSQL](/infrastructure/postgresql.md) DBMS host as
`dbms_connection_user` — and publishes/consumes on the
[RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange. It is a JVM
service (`JAVA_TOOL_OPTIONS` from the `java-tool-options` configmap, using the
`high` heap profile, with a 3Gi memory limit) listening on port 60000 and
exposed in-cluster as Service `metadata` on port 80. Other services reach it
via `baseurls_metadata` (`http://metadata`).

- **Source repo:** [cyverse-de/metadata](https://github.com/cyverse-de/metadata)
- **Image:** `harbor.cyverse.org/de/metadata` (pinned in
  `files/metadata.json`)

## Configuration

The role renders `templates/metadata.properties.j2` into the
`metadata-configs` secret, mounted at `/etc/iplant/de/metadata.properties`.
It is a short config: environment name (`ns`), database connection
(`groups['dbms'][0]`, `pg_listen_port`, `metadata_db_name`,
`dbms_connection_user`/`dbms_connection_pass`), and the AMQP URI built from
the `de_amqp_*` group_vars. Tracing exports to
[Jaeger](/infrastructure/jaeger.md) via OTEL variables from the `configs`
secret. Defaults: `metadata_replicas: 2` with required pod anti-affinity.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags metadata
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/metadata/templates/metadata.properties.j2` — database and AMQP configuration.
2. `ansible/roles/services/metadata/templates/k8s/metadata.yml.j2` — Deployment/Service, JVM env, resources.
3. `ansible/roles/services/metadata/files/metadata.json` — image and pinned tag/digest.
4. `ansible/roles/common/defaults/main.yml` — `metadata_db_name`, `baseurls_metadata`, `source_repos` entry.
