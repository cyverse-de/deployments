---
type: Service
title: portal-conductor
description: Account-provisioning API used by the user portal, acting on LDAP, iRODS, terrain, Mailman, and formation, with an exim sidecar for outbound mail.
resource: /ansible/roles/services/portal-conductor
tags: [portal, provisioning, ldap, irods, accounts]
timestamp: 2026-07-20T00:00:00Z
---

An account-provisioning API consumed by [portal2](/services/portal2.md). Its
configuration gives it admin credentials for [LDAP](/infrastructure/ldap.md)
(`portal_ldap_*`, community/everyone groups), [iRODS](/infrastructure/irods.md)
(`irods_*`, using the `rods` admin and `ipcservices` users),
[terrain](/services/terrain.md), Mailman mailing lists (`portal_mailman_*`),
and [formation](/services/formation.md) (with its own
[Keycloak](/infrastructure/keycloak.md) client and a user-deletion app name),
plus SMTP settings. The API itself is protected by basic auth
(`portal_conductor_auth_username`/`portal_conductor_auth_password`). The source
repo is [cyverse-de/portal-conductor](https://github.com/cyverse-de/portal-conductor)
and the image is `harbor.cyverse.org/de/portal-conductor`, pinned in
`ansible/roles/services/portal-conductor/files/portal-conductor.json`.

Configuration: the role renders `templates/portal-conductor.json.j2` into the
`portal-conductor-configs` secret (skipped when `load_configs` is false),
mounted at `/etc/cyverse/portal-conductor/portal-conductor.json` and located
via `PORTAL_CONDUCTOR_CONFIG`.

Runtime: a Deployment with `portal_conductor_replicas` (default 2) serving
HTTP on 8000 and HTTPS on 8443, with the serving cert/key mounted file-by-file
from the `portal-conductor-ssl` secret (so the system CA bundle is not
shadowed). An `exim4` sidecar on port 25 relays outbound mail from cluster
networks; see [Portal Exim](/playbooks/portal-exim.md). The Service exposes
80/443. [Bootstrap Portal Admin](/playbooks/bootstrap-portal-admin.md) uses
this service to create the initial admin's iRODS home.

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags portal-conductor`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/portal-conductor/templates/portal-conductor.json.j2` — LDAP, iRODS, terrain, mailman, formation, auth config.
[2] `ansible/roles/services/portal-conductor/templates/k8s/portal-conductor.yml.j2` — Deployment, exim sidecar, SSL mounts, Service.
[3] `ansible/roles/services/portal-conductor/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/portal-conductor/files/portal-conductor.json` — pinned image.
