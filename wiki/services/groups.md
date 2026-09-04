---
type: Service
title: groups
description: Group and membership API backed by the permissions schema of the DE database, replacing iplant-groups and Grouper.
resource: /ansible/roles/services/groups
tags: [groups, membership, postgresql, keycloak, amqp, api]
timestamp: 2026-09-03T00:00:00Z
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
CA or credential problem from a database one. It answers 503 when the database
ping fails and 200 otherwise — a Keycloak outage degrades lookups but does not
mark the pod unready.

Group authorization is delegated to the permissions service, where each group is
a resource of type `group`. **The resource's name is the group's external 32-hex
id**, not its name — a grant recorded against anything else authorizes nothing,
including for the group's own owner.

Group *management* — adding and removing members, granting and revoking
privileges, renaming, deleting — requires the **`admin`** level, not `write` or
`own`. The DE's precedence is `own=0, write=1, admin=2, read=3`, so `admin` sits
*below* write: asking for write locks out every co-admin, who are exactly the
subjects Grouper's `admins` privilege produced and whom terrain lists as team
admins. `own` still passes, being stronger.

**`groups_admin_users` must contain the account the DE services call this one
as** (`de_grouper`). It defaults to that for a reason: without it terrain, apps,
and [group-propagator](/services/group-propagator.md) see only what an ordinary
user sees. apps 500s resolving a community, because a group a non-admin cannot
see answers 403 rather than 404 and the client only catches 404; and the
propagator receives withheld member lists and a truncated crawl.

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

### Public does not mean the members are public

Grouper separated `viewers` — the group is discoverable and joinable — from
`readers`, which also exposes the member list, and gave public **teams** only
`viewers` while public **communities** got `readers`. The permissions service
has no level weaker than `read`, so both arrive as the same `GrouperAll` grant
and the difference is carried by `groups.members_public` (migration `000055`).

A non-member asking for a public team's members gets **200 with an empty list**,
carrying `"redacted": true`. The marker matters: without it a withheld list is
indistinguishable from an empty group, and the propagator's data-info update is
a *replace*, so it would strip the iRODS group and log the result as an
unremarkable "0 members". It refuses a redacted list instead.

It is not a 403. That is what Grouper did, and the DE's team page renders from it — a
403 breaks the page for every public team. Refusing is reserved for groups the
caller may not see at all.

### Joining is a third privilege again

Grouper spent three privileges on the all-users subject and the DE used all
three: `viewers` (discoverable), `readers` (members listable), and `optins` (a
user may add themselves). Public communities got `read` + `optin`; public teams
got `view` alone, so **Grouper refused a self-join on a public team** — those go
through the join-request flow, where an administrator approves.

`groups.joinable` (migration `000058`) carries `optins`, separately from
`members_public`. The two coincide in current data and mean different things:
gating a join on member visibility, or on the public marker alone, lets anyone
add themselves to any public team and bypasses that approval step entirely.

The importer derives both flags from Grouper's privileges and replaces the whole
set on each run, so a privilege revoked between runs reverts instead
of accumulating. Groups created natively have no `legacy_name` and are left
alone. terrain sets both at creation from `public_privileges`, which carries Grouper's
vocabulary: communities send `["read","optin"]`, public teams send `["view"]`.

## Groups are subjects

`GET /subjects` returns matching groups alongside matching users, tagged
`source_id: "g:gsa"`. Grouper did the same, and the DE's sharing dialog
recognizes a group by exactly that tag — return only users and sharing data,
apps, analyses, or tools with a team or collaborator list becomes unreachable
from the UI, with nothing raised anywhere.

The group half goes through the same access-filtered listing as `/groups`, so
the search cannot surface a group the caller could not already see. The `name`
is the group's short name, where Grouper returned the full colon-delimited path;
callers that strip the path (`name.split(":").pop()`) get the same answer from
both.

## Listings are access-filtered

`GET /groups` returns only what the acting user may read: a group they hold a
grant on directly or through a group they belong to, one they are an effective
member of, or a public one. Accounts in `groups_admin_users` see everything.

**The filter mirrors the read check exactly**, and has to. A group that lists
but cannot be opened is what produces "failed to get team details" in the DE; a
group that opens but never lists is unreachable. Both halves are the same four
conditions, one in SQL and one in the handler.

It is one set of `EXISTS` clauses inside the listing query rather than a
permission call per row, because production holds 2,583 groups and an N+1 would
be unusable. Measured against a production-sized dataset it costs about 13 ms.

Grouper's group search was privilege-filtered, so this is parity rather than a
new restriction. Without it any user can enumerate every team and community —
and every other user's personal collaborator lists — by name, description, and
owner: on a production-sized dataset a single page exposed 1,000 collaborator
lists belonging to 999 different users.

Source repo: [cyverse-de/groups](https://github.com/cyverse-de/groups); image
`harbor.cyverse.org/de/groups`, pinned in
`ansible/roles/services/groups/files/groups.json`.

Configuration: the role renders `templates/groups.yml.j2` into the
`groups-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/iplant/de/groups.yml` and passed via `--config`. Notable group_vars:
`groups_keycloak_client_id`/`groups_keycloak_client_secret`,
`groups_user_suffix`, `groups_admin_users`, and the shared
`dbms_connection_*`/`permissions_db_name` database settings.

`groups_userinfo_backend` selects where the service reads display names,
emails, and institutions: `keycloak` (the default) or `portal-conductor`. Both
read the same people — Keycloak federates the directory
[portal-conductor](/services/portal-conductor.md) queries directly — but the two
differ in cost and in coverage. Keycloak has no bulk lookup by username, so
resolving a member listing costs one request per member; portal-conductor
answers the whole listing in one. Keycloak also reports an institution only if
the realm carries an LDAP attribute mapper for the `o` attribute, and
`keycloak_config` does not create one, so under the Keycloak backend every
subject's institution is empty. Under `portal-conductor` it comes straight from
the directory.

Either way a directory outage degrades display data rather than authorization:
members are reported by bare identifier and the listing still succeeds.

`groups_user_suffix` is appended to a bare username to find the matching
`public.users` row, because `subjects.subject_id` holds bare usernames while
`public.users.username` carries a domain. A wrong value leaves those
correlations empty rather than failing, so it is worth checking per deployment.
The permissions service reads the same variable.

Runtime: a Deployment with `groups_replicas` (default 2) and optional pod
anti-affinity, listening on port 60000 behind a `groups` Service on port 80.
Readiness hits `/`, which gates it on the database (503 when the ping fails);
liveness hits `/healthz`, which touches nothing. Probing the database-backed
endpoint for liveness restarts every replica during a database outage, which a
restart cannot fix. Group create, update, delete, and membership changes are
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
rather than Grouper, so `group_data_source` should already read `native` —
[Cutting Group Management Over from Grouper](/playbooks/grouper-cutover.md) is
what moves it, and [Importing Groups from Grouper](/playbooks/grouper-import.md)
covers why running the importer after that point is destructive.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags groups`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/groups/templates/groups.yml.j2` — database, Keycloak, permissions, and AMQP settings.
[2] `ansible/roles/services/groups/templates/k8s/groups.yml.j2` — Deployment, Service, ports, probes.
[3] `ansible/roles/services/groups/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/common/defaults/main.yml` — `groups_*` group_vars and `terrain_groups_backend`.
[5] `ansible/roles/services/terrain/templates/terrain.properties.j2` — `terrain.groups.backend` and `terrain.groups.base-url`.
