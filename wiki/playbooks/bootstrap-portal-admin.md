---
type: Playbook
title: Bootstrapping a Portal Admin
description: How bootstrap_portal_admin.yml creates a login-capable portal admin across LDAP, the portal database, iRODS, and the DE.
resource: /ansible/bootstrap_portal_admin.yml
tags: [portal, admin, bootstrap, ldap, irods, terrain]
timestamp: 2026-07-20T00:00:00Z
---

Portal login is Keycloak/LDAP-only, so an admin needs both an LDAP identity
(to authenticate) and a portal `account_user` row with `is_staff=true`, keyed
by the same username. `bootstrap_portal_admin.yml` creates both, provisions
the admin's iRODS account and home collection, and registers the admin in the
DE so their users row and workspace exist without a first interactive login.
The playbook is idempotent and a no-op until `portal_bootstrap_user` is set.

```bash
ANSIBLE_JINJA2_NATIVE=True ansible-playbook -i <inventory> bootstrap_portal_admin.yml
```

## The plays

1. **LDAP identity** — port-forwards to the in-cluster
   [OpenLDAP](/infrastructure/ldap.md) service and creates the user entry
   (`inetOrgPerson`/`posixAccount`/`shadowAccount`), sets the password, and
   adds the user to the `everyone` group and the first group in
   `admin_groups` — the group whose membership becomes the `entitlement`
   claim terrain checks for DE admin. Binds as
   `cn=Manager,{{ ldap_dn_suffix }}` using `ldap_root_pw`.
2. **Portal `account_user` row** — connects to the portal database on the
   first `dbms` host as `portal_db_user` and inserts an `is_staff=true` row
   (superuser per `portal_bootstrap_superuser`), plus the matching
   `account_emailaddress` row the portal's Email card reads. Both inserts
   skip existing users.
3. **iRODS home via portal-conductor** — port-forwards to the in-cluster
   [portal-conductor](/services/portal-conductor.md) service and POSTs to
   `/datastore/users` with basic auth (`portal_conductor_auth_username`/
   `_password`). An existing user is treated as a password reset, so re-runs
   re-assert the shared password.
4. **DE registration via terrain** — port-forwards to the in-cluster
   [terrain](/services/terrain.md) service, exchanges the admin's basic-auth
   credentials for a Keycloak token at `/terrain/token/keycloak`, then calls
   `/terrain/secured/bootstrap`, which get-or-creates the DE users row and
   workspace. Port-forwarding is used instead of `portal_terrain_url` so this
   works before the public DE hostname resolves.

## Required variables and prerequisites

* `portal_bootstrap_user`, `portal_bootstrap_password`,
  `portal_bootstrap_email` must be set in the inventory (each play asserts
  the subset it needs). Name, institution, department, superuser flag, and
  uid number have defaults in `roles/common/defaults/main.yml`.
* `ldap_root_pw` (OpenLDAP Manager password) and `python-ldap` on the
  control host.
* `kubeconfig` for the target cluster; the kubectl port-forwards run under it.

# Citations

[1] `ansible/bootstrap_portal_admin.yml` — the playbook: all four plays and their auth described here.
[2] `ansible/roles/common/defaults/main.yml` — `portal_bootstrap_*` defaults and `ldap_local_port`.
