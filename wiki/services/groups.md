---
type: Service
title: groups
description: Group and membership API backed by the permissions schema of the DE database, replacing iplant-groups and Grouper.
resource: /ansible/roles/services/groups
tags: [groups, membership, postgresql, keycloak, amqp, api]
timestamp: 2026-08-05T00:00:00Z
---

The groups service is the intended replacement for
[iplant-groups](/services/iplant-groups.md), and with it
[Grouper](/infrastructure/grouper.md). Groups, membership, and the materialized
effective-membership closure live in the `permissions` schema of the DE database
— the same schema the [permissions](/services/permissions.md) service owns — so
expanding a subject to its groups is a join rather than a call to another
service. The schema comes from `de-database` migration `000054`.

[Keycloak](/infrastructure/keycloak.md) supplies user attributes only: names,
email addresses, and institutions. The service account needs to read users, not
to manage groups. A directory outage therefore degrades display data rather than
authorization, with one deliberate exception — adding a member who has no
subject row yet requires Keycloak, because that is where the username is
verified.

That lookup runs against the DE realm, not master, so the client and its
`realm-management`/`view-users` grant both live there; see
[which realm a service account's roles come from](/infrastructure/keycloak.md).
Because the call is HTTPS, the deployment manifest carries the `de_ca_*`
partials, so a deployment with a private CA trusts it. The Grouper importer
deliberately carries none: it reaches Grouper and the DE database over
`postgresql` with `sslmode` disabled and the permissions service over plain
HTTP, so it opens no TLS connection at all. `GET /` reports both dependencies
(`{"database":true,"keycloak":true}`), which is the quickest way to tell a
CA or credential problem from a database one.

Group authorization is delegated to the permissions service, where each group is
a resource of type `group`. **The resource's name is the group's external 32-hex
id**, not its name — a grant recorded against anything else authorizes nothing,
including for the group's own owner. Accounts listed in `groups_admin_users`
bypass every per-group check and have full administrative control over all
groups, so only trusted internal DE services belong there.

## How a group is marked public

A public team or community carries a `read` grant held by **`GrouperAll`**, a
group-typed subject with no members and no `groups` row. It is checked as
itself, without group expansion: no user is ever a member of it, so the
acting-user check — which expands a user to their groups — cannot see the grant.
Reading a group succeeds if the user holds read, *or* the group is public, *or*
the user is a member.

That ordering is load-bearing. Checking only the acting user makes every public
group unreadable to non-members, which is not how [Grouper](/infrastructure/grouper.md)
behaved — its privilege engine resolved `GrouperAll` as everyone. Production has
roughly 183 public teams and 55 public communities, so the difference is a
browse-teams flow that works against Grouper and 403s against this service.

Do not look for `GrouperAll` in `grouper_memberships_v` when reasoning about
this. That view is membership, and `GrouperAll` is never in it; the public
marker lives in the privilege fields (`viewers`, `readers`, `optins`) in
`grouper_memberships_all_v`.

**One deliberate widening.** Grouper distinguished `viewers` (see the group)
from `readers` (see its members), and gave public *teams* only `viewers` — so a
non-member saw the team with an empty member list. The importer maps both to a
single `read` grant, because the permissions service has no equivalent
distinction, so a public team's membership is now visible to any user where
Grouper hid it. Public communities are unaffected: they carried `readers`
already.

Source repo: [cyverse-de/groups](https://github.com/cyverse-de/groups); image
`harbor.cyverse.org/de/groups`, pinned in
`ansible/roles/services/groups/files/groups.json`.

Configuration: the role renders `templates/groups.yml.j2` into the
`groups-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/iplant/de/groups.yml` and passed via `--config`. Notable group_vars:
`groups_keycloak_client_id`/`groups_keycloak_client_secret`,
`groups_user_suffix`, `groups_admin_users`, and the shared
`dbms_connection_*`/`permissions_db_name` database settings.

`groups_user_suffix` is appended to a bare username to find the matching
`public.users` row, because `subjects.subject_id` holds bare usernames while
`public.users.username` carries a domain. A wrong value leaves those
correlations empty rather than failing, so it is worth checking per deployment.
The permissions service reads the same variable.

Runtime: a Deployment with `groups_replicas` (default 2) and optional pod
anti-affinity, listening on port 60000 behind a `groups` Service on port 80.
Health probes hit `/`. Group create, update, delete, and membership changes are
published to the `de` exchange on the DE [RabbitMQ](/infrastructure/rabbitmq.md)
broker for downstream re-indexing, matching the messages iplant-groups emitted.

The role also deploys the Grouper importer that populates this schema — see
[Importing Groups from Grouper](/playbooks/grouper-import.md).

## Switching terrain over

`terrain_groups_backend` selects which store
[terrain](/services/terrain.md) reads groups from: `iplant-groups` (the default,
via [Grouper](/infrastructure/grouper.md)) or `groups`. It is rendered as
`terrain.groups.backend`, and it is terrain's rollback path — flipping it back
needs no redeploy of anything else.

**Do not set it to `groups` until the deployed [apps](/services/apps.md) image
tags communities by ID.** On the new backend nothing blocks a community rename,
so an older apps orphans every tag the first time a community is renamed, with
nothing raised anywhere — see
[Rewriting App Community Tags](/playbooks/community-tags.md).

Two shapes change the moment it flips, both of which a caller can consume
without erroring:

- A group's `display_name` becomes its short name. Under Grouper it was the full
  colon-delimited path.
- `id_index` is empty; it was a Grouper-internal counter with no equivalent here.

Group IDs do **not** change: an imported group keeps its Grouper UUID, so
permission grants and iRODS `@grouper-<id>` names are unaffected.

Flipping it is also the point at which group writes start landing in Postgres
rather than Grouper, so `group_data_source` should already read `native` — see
[Importing Groups from Grouper](/playbooks/grouper-import.md) for why running
the importer after that point is destructive.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags groups`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/groups/templates/groups.yml.j2` — database, Keycloak, permissions, and AMQP settings.
[2] `ansible/roles/services/groups/templates/k8s/groups.yml.j2` — Deployment, Service, ports, probes.
[3] `ansible/roles/services/groups/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/common/defaults/main.yml` — `groups_*` group_vars and `terrain_groups_backend`.
[5] `ansible/roles/services/terrain/templates/terrain.properties.j2` — `terrain.groups.backend` and `terrain.groups.base-url`.
