---
type: Service
title: openldap-docker
description: In-cluster OpenLDAP directory for DE deployments without an external LDAP server, deployed as a StatefulSet with config and seed data rendered from templates.
resource: /ansible/roles/services/openldap-docker
tags: [openldap, ldap, directory, statefulset, authentication]
timestamp: 2026-07-21T00:00:00Z
---

Runs an OpenLDAP (`slapd`) directory inside the Kubernetes cluster for
deployments that have no external LDAP server. See [OpenLDAP](/infrastructure/ldap.md)
for the broader LDAP setup. The source repo is
[cyverse-de/openldap-docker](https://github.com/cyverse-de/openldap-docker) and the
image is `harbor.cyverse.org/de/openldap`, pinned in
`ansible/roles/services/openldap-docker/files/openldap-docker.json`.

This role is unusual among the service roles:

- It only runs when `ldap_in_cluster` is true, and it deploys into its own
  namespace (`ldap_ns`) rather than the DE namespace.
- There is no app config template. Instead it renders two secrets before the
  skaffold deploy: `openldap-config` (from `slapd.conf.j2`: `ldap_dn_suffix`,
  `ldap_rootpw_hash`, mdb backend, indexes, ACLs) and `openldap-seed` (from
  `seed.ldif.j2`: base DN, `ou=People`/`ou=Groups`, the `everyone`,
  `de_admins`, and `community` groups (portal-conductor adds every new portal
  user to `community` during registration), and the `de_grouper` and
  `ldap_reader` accounts with `ldap_de_grouper_pw_hash` /
  `ldap_ldap_reader_pw_hash`).
- The manifest is a StatefulSet (`openldap_replicas`,
  `openldap_pod_anti_affinity`) with a 1Gi PVC for the mdb database. Init
  containers convert `slapd.conf` to the `cn=config` tree on every boot and
  bulk-load the seed LDIF once (skipped when `data.mdb` already exists).
- `slapd` runs as uid 65532 and listens on 1389/1636; the `openldap` Service
  exposes the standard ports 389 (ldap) and 636 (ldaps).

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags openldap-docker`;
see [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/openldap-docker/tasks/main.yml` — namespace, secret rendering, `ldap_in_cluster` guard.
[2] `ansible/roles/services/openldap-docker/templates/k8s/openldap-docker.yml.j2` — StatefulSet, init containers, ports, PVC.
[3] `ansible/roles/services/openldap-docker/templates/slapd.conf.j2`, `ansible/roles/services/openldap-docker/templates/seed.ldif.j2` — rendered config and seed entries.
[4] `ansible/roles/services/openldap-docker/files/openldap-docker.json` — pinned image.
