---
type: Service
title: Grouper
description: How the grouper_init role deploys Grouper in-cluster — config secret, one-time database and folder initialization via a gsh pod, and the grouper-loader and grouper-ws workloads.
resource: /ansible/roles/grouper_init
tags: [grouper, groups, ldap, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

Grouper is the groups-management service backing DE permissions; the DE talks to it through
`grouper-ws` (the `baseurls_grouper_web_services` default points at
`http://grouper-ws/grouper-ws`, consumed by [iplant-groups](/services/iplant-groups.md)).
Grouper is installed inside the same cluster as the DE, but the process is different enough
from the other services that it has its own role, `grouper_init`, which runs in
`kubernetes.yml` under the `grouper` tag:

```bash
ansible-playbook -i <inventory> --tags grouper kubernetes.yml
```

## What the role does

1. Creates the `grouper-configs` Secret in the DE namespace (`ns`) from eleven templated
   properties files. `grouper-hibernate.properties` points at the
   [PostgreSQL](/infrastructure/postgresql.md) `grouper` database
   (`grouper_db_host`/`grouper_db_port`/`grouper_db_name`, `grouper_db_user`/`grouper_db_pass`);
   `grouper-loader.properties` configures the [LDAP](/infrastructure/ldap.md) subject and
   group sources (`grouper_loader_url`, `grouper_loader_user`, `grouper_loader_password`).
2. Unless `skip_db_init` is set true, starts a `gsh` pod from
   `{{ grouper_gsh_image }}:{{ grouper_gsh_image_version }}` and runs
   `gsh -registry -check -runscript -noprompt` in it — Grouper initializes its own schema;
   the database role/DB just need to exist beforehand.
3. Copies a generated `grouper_init.groovy` into the pod and runs it. The script saves the
   WS credentials (`grouper_connection_user`/`grouper_connection_pass`), creates the
   `iplant` and `iplant:ldap` folders, sets up the `iplant:ldap:ldap-group-loader` group
   with an `LDAP_GROUP_LIST` loader job (filter `objectClass=posixGroup`, hourly cron,
   loading into `iplant:ldap:groups:*`), creates `iplant:de:{{ ns }}` with privileges
   granted to the LDAP `de_grouper` user, and — as `de_grouper` — creates the
   `iplant:de:{{ ns }}:users` folder and the `de-users` role group.
4. Deploys `grouper-loader` (a Deployment running `gsh -loader`, `grouper_loader_replicas`
   default 1) and `grouper-ws` (Deployment plus a `grouper-ws` Service on port 80,
   `grouper_ws_replicas` default 2), both from `harbor.cyverse.org/de/grouper:{{ grouper_tag }}`
   with pod anti-affinity across nodes.

## Operator notes

- The init blocks fail the play if `gsh` exits non-zero, but the `gsh` pod is not deleted
  afterward; it stays in the namespace until you remove it.
- The Groovy script uses `INSERT` save mode for the top-level folders, so re-running the
  init against an already-initialized registry is not idempotent.
- `grouper-ws` readiness/liveness probes allow a 180-second initial delay — startup is slow.

# Citations

[1] `ansible/roles/grouper_init/tasks/main.yml` — secret creation, gsh init pod, Groovy script, and the loader/ws deployments.
[2] `ansible/roles/grouper_init/templates/` — the eleven properties files placed in the `grouper-configs` secret.
[3] `ansible/kubernetes.yml` — the `grouper` tag on the `grouper_init` role.
[4] `ansible/README.md` — the Grouper section (tag usage, schema self-initialization).
[5] `ansible/roles/common/defaults/main.yml` — `grouper_*` variable defaults.
