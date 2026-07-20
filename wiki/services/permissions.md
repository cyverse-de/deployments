---
type: Service
title: permissions
description: DE permissions service backed by its own PostgreSQL database, with read access to the Grouper database for group information.
resource: /ansible/roles/services/permissions
tags: [permissions, authorization, postgresql, grouper]
timestamp: 2026-07-20T00:00:00Z
---

The DE permissions service. Its configuration gives it two database
connections: its own permissions database (schema `permissions`) on the
[PostgreSQL](/infrastructure/postgresql.md) DBMS host, and the
[Grouper](/infrastructure/grouper.md) database (`grouper_db_*` vars plus
`grouper_folder_name_prefix`), so it can resolve group information alongside
its own permission records. The source repo is
[cyverse-de/permissions](https://github.com/cyverse-de/permissions) and the image
is `harbor.cyverse.org/de/permissions`, pinned in
`ansible/roles/services/permissions/files/permissions.json`.

Configuration: the role renders `templates/permissions.yaml.j2` into the
`permissions-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/iplant/de/permissions.yaml` and passed via `--config`. Notable group_vars:
`dbms_connection_user`/`dbms_connection_pass`, `permissions_db_name`,
`pg_listen_port`, and the `grouper_db_*` connection settings.

Runtime: a Deployment with `permissions_replicas` (default 2) and optional pod
anti-affinity, listening on port 60000 behind a `permissions` Service on port
80. OpenTelemetry tracing goes to [Jaeger](/infrastructure/jaeger.md) via
`OTEL_*` env vars from the shared `configs` secret. Health probes hit `/`.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags permissions`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/permissions/templates/permissions.yaml.j2` — permissions and Grouper DB connections.
[2] `ansible/roles/services/permissions/templates/k8s/permissions.yml.j2` — Deployment, Service, ports, OTEL env.
[3] `ansible/roles/services/permissions/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/permissions/files/permissions.json` — pinned image.
[5] `ansible/roles/services/permissions/defaults/main.yml` — replica and anti-affinity defaults.
