---
type: Service
title: permissions
description: DE permissions service backed by the permissions schema of the DE database, reading group membership from the same schema.
resource: /ansible/roles/services/permissions
tags: [permissions, authorization, postgresql, groups]
timestamp: 2026-07-27T00:00:00Z
---

The DE permissions service, backed by the `permissions` schema on the
[PostgreSQL](/infrastructure/postgresql.md) DBMS host.

Group membership lives in that same schema, written by the
[groups](/services/groups.md) service, so a permission check expands a subject to
its groups with a join instead of a call to another service. The service no
longer connects to [Grouper](/infrastructure/grouper.md) at all; the `grouperdb`
section is retained in the rendered config **for rollback only**, because the
previous image fails to start without it. Remove it once the rollback window has
closed. The conversion commands under `conversions/` in the source repo still
read Grouper directly and are unaffected.

The source repo is
[cyverse-de/permissions](https://github.com/cyverse-de/permissions) and the image
is `harbor.cyverse.org/de/permissions`, pinned in
`ansible/roles/services/permissions/files/permissions.json`.

Configuration: the role renders `templates/permissions.yaml.j2` into the
`permissions-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/iplant/de/permissions.yaml` and passed via `--config`. Notable group_vars:
`dbms_connection_user`/`dbms_connection_pass`, `permissions_db_name`,
`pg_listen_port`, `groups_user_suffix` (shared with the groups service — the two
must agree, or they correlate subjects differently), and
`permissions_max_expanded_subjects`.

`permissions_max_expanded_subjects` (default 10000) caps how many subjects one
resource's permissions may expand to when a caller passes `expand_groups`. The
`de-users` group contains essentially every DE user, so an uncapped expansion of
a public resource is unbounded work. Exceeding the cap is an error rather than a
truncated list.

Runtime: a Deployment with `permissions_replicas` (default 2) and optional pod
anti-affinity, listening on port 60000 behind a `permissions` Service on port
80. OpenTelemetry tracing goes to [Jaeger](/infrastructure/jaeger.md) via
`OTEL_*` env vars from the shared `configs` secret. Health probes hit `/`.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags permissions`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/permissions/templates/permissions.yaml.j2` — database, username suffix, and expansion cap.
[2] `ansible/roles/services/permissions/templates/k8s/permissions.yml.j2` — Deployment, Service, ports, OTEL env.
[3] `ansible/roles/services/permissions/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/permissions/files/permissions.json` — pinned image.
[5] `ansible/roles/services/permissions/defaults/main.yml` — replica and anti-affinity defaults.
