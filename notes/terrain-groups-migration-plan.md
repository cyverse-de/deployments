> # ⚠️ SUPERSEDED — DO NOT FOLLOW
>
> This plan (Phases D–H) describes finishing the terrain client written against
> the **abandoned Keycloak-backed** groups service — the one that packed the DE's
> hierarchy into colon-delimited group names. That client was rewritten on
> 2026-07-27 (`terrain` commit `4946665`): the name-packing layer is gone, groups
> resolve by structured identity, and `terrain.clients.grouping.retag` — which
> this document references — has been deleted.
>
> Current plan: `~/.claude/plans/foamy-puzzling-cascade.md` (Phase 5 replaces
> everything below). Kept only for the reasoning history.

# Terrain Groups-Migration Completion Plan (Phases D–H)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take terrain from "Groups-backed code paths exist behind a config toggle" to "the toggle can be flipped in QA and production."

**Where things stand:** branch `new-groups` (6 commits, `origin/main`..`ef5b952`) already contains a complete `terrain.clients.groups` client (73 fns, 684 lines), the `terrain.clients.grouping` dispatch facade, the cycle-safe `grouping.subjects` and `grouping.retag` helpers, and `terrain.groups.{base-url,admin-user,backend}` config. Every `iplant-groups` call site in `src/` now goes through the facade — verified by comparing the set of `ipg/…` symbols used across `src/` against the facade's public fns: zero uncovered. All groups-service endpoints the client calls exist. So the remaining work is **not** "write more client functions"; it is correctness at scale, test coverage, provisioning, data migration, and the cutover itself.

**Branch:** continue on `new-groups` in `/home/johnw/work/src/github.com/cyverse-de/terrain`. Cross-repo tasks land on a new branch in `/home/johnw/work/src/github.com/cyverse-de/groups`.

## Global Constraints

- Clojure. Follow the Clojure Style Guide; lint with `clj-kondo --lint src/ test/`; test with `lein test`. **Delimiter discipline:** small targeted edits, verify balance after every edit to a `.clj` file.
- The default for `terrain.groups.backend` stays `iplant-groups` until Phase H. Every change must leave the legacy path byte-for-byte unchanged in behavior.
- Terrain's external HTTP contract (swagger schemas, response shapes) must not change. Consumers (sonora, apps) are unmodified.
- Groups-repo changes must not alter existing endpoint request/response shapes — additive query parameters only, so the permissions-service PR (#30) and the terrain client keep working.
- No new dependencies in terrain unless there is no stdlib/existing-dep option.

## Blocking cross-cutting risk (read before Phase H)

`apps` still reads group data directly from iplant-groups/Grouper (~11 endpoints: de-users and workshop groups by name, subject lookups, subject→groups for job listings, group members for share notifications, community-admin privileges). `group-propagator` likewise mirrors Grouper groups into iRODS as `@grouper-<groupID>`.

If terrain flips to the Groups service while apps still reads Grouper, group writes made through terrain (new teams, collaborator lists, community membership) will be invisible to apps, and iRODS ACLs will drift. **Terrain's cutover cannot ship alone.** Phase H is gated on apps being migrated (or on an accepted, explicitly scoped read-only divergence window). Phases D–G are safe to do now and are prerequisites either way.

## Out of Scope (do not do these)

- Migrating `apps`, `group-propagator`, `dashboard-aggregator`, `requests`, `timelord`, or `sonora`.
- Deleting `terrain.clients.iplant-groups`, the `grouping` facade, or the `terrain.groups.backend` toggle. They stay as the rollback path; removal is a later cleanup branch.
- Building the migration tool itself (Phase G designs it; implementation is a separate effort).
- The iRODS `@grouper-<id>` → Keycloak-ID rename.

---

## Phase D — Groups service: name resolution and result completeness

Terrain's client encodes hierarchy in flat group names (`de:teams:<creator>:<short>`, `de:communities:<short>`, `de:users:<user>:collaborator-lists:<short>`) and resolves a name to a UUID by calling `GET /groups?search=<name>` and filtering for an exact `:name` match (`find-group-by-name`, `groups.clj:122`). Folder listings (`get-teams`, `get-communities`, `get-collaborator-lists`) do the same with a prefix filter.

`SearchGroupsHandler` (`cmd/groups/groups.go:41`) passes `search` straight to `gocloak.GetGroups` with no `First`/`Max`, and `SearchSubjectsHandler` (`cmd/groups/subjects.go:29`) does the same for users. Keycloak caps an unparameterized query at its default page size (100). **Consequence:** once a folder exceeds that many groups, listings silently truncate and `resolve-group-id` can return 404 for a group that exists — a data-loss-shaped bug (terrain would report "group not found" and, in `add-collaborator-list-members`, create a duplicate list).

### Task D1: exact group lookup by name (groups repo)

- Add an exact-name lookup so terrain never has to search-then-filter. Preferred shape: `GET /groups?name=<exact>` returning 0-or-1 group, implemented with a Keycloak search plus an exact-match filter server-side, paging until found. Keep `search` behavior unchanged.
- Alternative if the handler grows awkward: a dedicated `GET /groups/by-name/:name` route. Decide in the task; document the choice.
- Update swagger annotations and regenerate docs (CI checks staleness).
- Tests: exact match found; no match → 404; a name that is a strict prefix of another group's name resolves to the right one; a match that falls beyond the first Keycloak page is still found.

### Task D2: complete results for prefix listings (groups repo)

- Make `SearchGroupsHandler` and `SearchSubjectsHandler` return the full result set by paging through Keycloak internally (`First`/`Max` loop) rather than a single default-capped call.
- Bound it: a configurable maximum (`search.max_results`, default generous — e.g. 10000). On hitting the bound, log at warn with the probable cause ("search result cap reached; the folder likely exceeds the configured limit and results are truncated") rather than silently truncating.
- Optionally expose `first`/`max` query params for future paged callers; additive only.
- Tests: a mocked Keycloak returning three pages yields all results; the cap truncates and logs; empty search still works.

### Task D3: decide on read authorization for group search (groups repo — decision first)

`SearchGroupsHandler` performs no per-group permission check, so any authenticated caller can enumerate every group in the realm, including other users' collaborator lists (names + descriptions). Terrain's client filters by folder so nothing breaks functionally, but this is an information-disclosure regression relative to Grouper's folder privileges.

- **Investigate first, then decide.** Options: (a) accept and document, since the endpoint is internal-only and terrain filters; (b) filter results by the caller's read/member access, which costs one permissions call per result unless the permissions service can list a subject's readable resources in bulk; (c) restrict `search` to admin users and give terrain a narrower purpose-built endpoint.
- Do not implement (b) without confirming a bulk-permission-lookup path exists — the naive version makes every team listing O(n) HTTP calls.
- Output: a short decision note in the groups repo (or this file) plus whatever implementation follows.

### Task D4: terrain uses the new lookups

- Point `find-group-by-name` / `resolve-group-id` (`src/terrain/clients/groups.clj`) at the D1 exact-name endpoint.
- Leave the prefix-listing helpers on `search`, now that D2 makes them complete.
- Update `test/terrain/clients/groups_test.clj` route stubs accordingly.

---

## Phase E — Terrain parity and test coverage

### Task E1: close the client test gaps

`test/terrain/clients/groups_test.clj` (382 lines, 28 `deftest`s) covers subject lookup, collaborator-list basics, most team operations, and the community happy paths. Untested public fns, all of which mutate or read remote state:

`format-like-trellis`, `update-collaborator-list`, `remove-collaborator-list-members`, `update-team`, `verify-team-exists`, `get-team-members`, `remove-team-members`, `get-community`, `update-community`, `get-community-members`, `get-community-admins`, `remove-community-admins`, `leave-community`.

- Add tests in the existing style (route-stub server, assert on the requests issued as well as the parsed result). Table-driven where the shapes repeat — the name-encode/strip-folder round trip is the same for all three entity families and should be exercised once per family, not once per function.
- Cover the encode/strip asymmetries explicitly: a team rename preserves the creator prefix (`update-team`, `groups.clj:345`); a collaborator-list rename re-qualifies under the caller's folder; `strip-folder` uses `\Q…\E` quoting, so a name containing regex metacharacters must round-trip.

### Task E2: facade and helper tests

- `terrain.clients.grouping` has no tests. Add a dispatch test that, with `config/groups-backend` bound to each value, asserts each facade fn reaches the intended backend. Redef-based stubs over both client namespaces keep this cheap; one table over the fn list beats 40 near-identical deftests.
- `terrain.clients.grouping.retag`: cover the rename path — tagged apps found (rename blocked unless forced), none found, force-rename. Note the known limitation already recorded in the Phase C commit: retagging only matches tags in the new `de:communities:<name>` format; legacy tag values are a Phase G data concern.
- `terrain.clients.grouping.subjects`: assert the dispatch, and that it stays free of the `user-attributes` dependency cycle.

### Task E3: response-parity audit against iplant-groups

Produce a written comparison (commit it under `docs/` in terrain or append here) of each deliberate deviation, with a keep/fix decision for each:

- `format-group` synthesizes `:type "group"` and `:id_index ""` (`groups.clj:90`). Confirm no consumer keys off `id_index`; sonora and terrain's own schemas are the ones to check.
- `get-communities` returns `:privileges []` unconditionally (`groups.clj:556`), by design. Confirm the DE UI really derives admin/follower state from `/admins` and `/members` — if any caller reads `privileges`, this is a bug, not an optimization.
- `format-member-results` defaults a blank `source_id` to `"unknown"` (`groups.clj:147`). The legacy backend emitted `"ldap"`/`"g:gsa"`. Decide whether `"unknown"` can reach a consumer that compares against those values.
- The `details` argument to `get-collaborator-lists`/`list-groups-for-user` is ignored, and the legacy sorting/paging query params are dropped. Verify no route exposes them to clients in a way that now silently no-ops.
- `lookup-subject` swallows non-404 errors and returns `nil` (`groups.clj:64`), converting a groups-service outage into "user not found" at some call sites. The legacy client propagated. Recommend: keep the 404→nil mapping, let other failures propagate, and confirm `auth.user_attributes` still degrades the way it needs to.
- `list-groups-for-user` always acts as the admin user (`groups.clj:102`) whereas the legacy path used the caller. Confirm this is intended and cannot leak group membership to an unprivileged caller through terrain's routes.

---

## Phase F — Provisioning and deployment configuration

### Task F1: bootstrap the well-known groups and subjects

Nothing in the groups service or Keycloak provisioning creates the objects terrain assumes exist:

- `de:users:<de-users-group>` (default `de:users:de-users`), required by `remove-de-user` (`groups.clj:677`) and by the `DELETE /groups/de-users/members/:subject-id` route.
- The public subject `GrouperAll` (`groups.clj:275`), granted `read` as a **group**-type subject to make a team or community joinable. Confirm the permissions service accepts an opaque group subject ID that is not a Keycloak group, or create a real Keycloak group for it.
- The `de:teams`, `de:communities`, and per-user `de:users:<user>:collaborator-lists` names are created on demand, so they need no seeding — verify that on-demand creation is actually permitted for an ordinary caller.

Deliver: an idempotent provisioning step (ansible task or a groups-service bootstrap) plus documentation of what must exist before the toggle flips.

Note: terrain also grows a *second* admin-user config (`terrain.groups.admin-user`, defaulting to `de_grouper`) alongside `terrain.iplant-groups.grouper-user`. Confirm that account is in the groups service's `admin.users` list (see the permissions plan, Task 1) — without that, every `join-team`/`leave-team`/`remove-de-user` call fails authorization.

### Task F2: deployments wiring

- `ansible/roles/services/terrain/templates/terrain.properties.j2` currently emits only `terrain.iplant-groups.base-url` (line 66). Add `terrain.groups.base-url`, `terrain.groups.admin-user`, and `terrain.groups.backend`, driven by inventory variables with the legacy backend as the default.
- Add `baseurls_groups` (or equivalent) to `ansible/roles/common/defaults/main.yml` and the example inventory.
- The groups service itself still has no deployment role — that is tracked separately, but terrain's config cannot be validated until it exists.

---

## Phase G — Data migration design

Design (do not build) the Grouper → Keycloak move for everything terrain reads and writes. Deliverable is a specification precise enough to implement and to verify afterward.

- **Inventory:** collaborator lists, teams (incl. creator prefix), communities, `de-users` membership, and the privileges attached to each.
- **Name mapping:** legacy Grouper folder-qualified names → the flat encoded names terrain now uses. Enumerate every legacy form actually present in the QA and production Grouper databases rather than assuming.
- **Privilege mapping:** Grouper privileges → permissions-service grants, using terrain's translation as the reference (`own`/`admin` → `admin`, `write`/`read` → `read`, public subject → `view`; `groups.clj:445-460`). Public teams/communities must end up with the `GrouperAll` read grant.
- **App tags:** community names are embedded in app tag values. `grouping.retag` only recognizes the new `de:communities:<name>` format, so legacy tag values need a rewrite pass in the same migration.
- **Ordering and idempotency:** groups before memberships before permissions; re-runnable; a dry-run mode that reports what would change.
- **Verification:** per-entity counts and a spot-check query set that can be run before and after and diffed.
- **Rollback:** what "undo" means once terrain has written to Keycloak (it is not symmetric — plan a freeze window instead of a reverse migration).

---

## Phase H — Cutover

Gated on the cross-cutting risk above: do not flip until `apps` is migrated or a divergence window is explicitly accepted.

### Task H1: QA smoke checklist

An endpoint-by-endpoint manual checklist run against QA with `terrain.groups.backend = groups`, covering each facade family: subject search/lookup, collaborator list CRUD + membership, team CRUD + membership + join/leave + privileges + admins, community CRUD + membership + admins + join/leave + rename-with-retag, and `de-users` removal. Each item records expected vs. actual response shape, not just a status code — the parity deviations from E3 are exactly what a status-code-only check would miss.

### Task H2: flip the toggle

- QA first, soak, then production, via the inventory variable from F2.
- Keep the facade and the legacy client in place; rollback is a config change plus a restart.
- Record what was observed during the soak so the eventual cleanup branch (removing the facade) has evidence behind it.

---

## Open questions to resolve while executing

- D3's authorization decision needs a bulk-permission-lookup answer from the permissions service before option (b) is viable.
- Whether the `GrouperAll` public subject should become a real Keycloak group (F1) affects both the migration (G) and sonora's `grouper.allUsers` constant.
- Whether any consumer reads `id_index` or `privileges` from terrain's group responses (E3) — if one does, the current shortcuts become defects rather than deviations.
