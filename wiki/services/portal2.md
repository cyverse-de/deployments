---
type: Service
title: portal2
description: The CyVerse user portal web application, handling account self-registration, sessions, and service access via Keycloak, portal-conductor, and terrain.
resource: /ansible/roles/services/portal2
tags: [portal, user-portal, nodejs, keycloak, accounts]
timestamp: 2026-07-20T00:00:00Z
---

The CyVerse user portal, a Node.js web application (`NODE_ENV=production`,
port 3000) deployed under the name `user-portal`. Its configuration wires it to
its own portal database on [PostgreSQL](/infrastructure/postgresql.md)
(including a session table), [Keycloak](/infrastructure/keycloak.md) for login
(`portal_keycloak_*`), [portal-conductor](/services/portal-conductor.md) for
account provisioning actions (with basic auth), and
[terrain](/services/terrain.md) with a service account for DE calls. It also
carries SMTP, Intercom, Sentry, Google Analytics, honeypot, and HMAC-key
settings. The source repo is
[cyverse-de/portal2](https://github.com/cyverse-de/portal2) and the image is
`harbor.cyverse.org/de/portal2`, pinned in
`ansible/roles/services/portal2/files/portal2.json`.

Configuration: the role renders `templates/portal2.json.j2` into the
`portal2-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/cyverse/portal2/portal2.json` and located via `CONFIG_PATH`. Notable
group_vars: `portal_db_*`, `portal_session_*`, `portal_keycloak_*`,
`portal_conductor_url` and `portal_conductor_auth_*`, `portal_terrain_*`,
`portal_ui_base_url`, `portal_smtp_*`, and `portal_uid_number_offset`.

Runtime: a Deployment with `portal2_replicas` (default 1), its own `timezone`
ConfigMap (America/Phoenix), a readiness probe on `/api/ready`, and a
`user-portal` Service on port 3000. Bootstrapping an initial admin account is
covered by [Bootstrap Portal Admin](/playbooks/bootstrap-portal-admin.md).

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags portal2`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/portal2/templates/portal2.json.j2` — DB, Keycloak, portal-conductor, terrain, SMTP config.
[2] `ansible/roles/services/portal2/templates/k8s/portal2.yml.j2` — Deployment, Service, env, readiness probe.
[3] `ansible/roles/services/portal2/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/portal2/files/portal2.json` — pinned image.
