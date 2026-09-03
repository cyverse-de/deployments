---
type: Playbook
title: Cutting Group Management Over from Grouper
description: How grouper_cutover.yml flips the group_data_source marker that makes the DE database authoritative for group data, what it checks first, and how to hand group data back to Grouper.
resource: /ansible/grouper_cutover.yml
tags: [grouper, groups, migration, cutover, permissions, database]
timestamp: 2026-09-03T00:00:00Z
---

By the time this playbook runs, the DE's group data is already in the
`permissions` schema — [grouper-import](/playbooks/grouper-import.md) put it
there. What is left is deciding which store is authoritative, and that is a
single row: `permissions.group_data_source`, seeded `grouper` by `de-database`
migration `000057`.

`grouper_cutover.yml` moves that row to `native`, having first checked
everything the move depends on.

```bash
ansible-playbook -i <inventory> grouper_cutover.yml --tags=preflight
ansible-playbook -i <inventory> grouper_cutover.yml
ansible-playbook -i <inventory> grouper_cutover.yml --tags=rollback
```

## What the marker actually gates

One thing reads it: `RequireGrouperAuthoritative`, at the top of every importer
run. While it says `grouper` the importer reconciles; once it says `native` the
importer refuses, with no override flag. That refusal is the point. The import
is convergent — it removes memberships and grants Grouper no longer has — so
running it after cutover would delete group data users created natively.

The guard sits ahead of the dry-run check, so **after the flip even
`-e dry_run=true` refuses.** Anything that needs to read Grouper and compare has
to happen before the marker moves, which is why the reconciliation gate is in
`preflight` rather than `verify`.

## Ordering

The marker moves after the import and before terrain is pointed at the new
backend. Both halves matter:

1. Apply the `de-database` migrations.
2. Deploy [groups](/services/groups.md) and
   [permissions](/services/permissions.md).
3. Run [grouper-import](/playbooks/grouper-import.md) and read its report.
4. Run [community-tags](/playbooks/community-tags.md).
5. Run this playbook.
6. Set `terrain_groups_backend: groups`, re-run `configure-services`, and deploy
   terrain, apps, group-propagator, and sonora.

Flipping before 3 cuts the DE over to group data nothing has populated. Flipping
after 6 leaves terrain writing natively while the importer is still willing to
reconcile those writes away.

## The plays

Each is separately tagged (`preflight`, `flip`, `verify`, `rollback`).
`rollback` also carries `never`, so a default run cannot reach it.

1. **Preflight** — read-only, and worth running a week early: every check that
   fails on the day is one that could have been answered sooner. It requires an
   operator name for the audit row, that `permissions.group_data_source` exists,
   that the `grouper-import` CronJob is present and suspended, that `groups` and
   `permissions` have available replicas, and that the import has actually
   landed rows.
2. **Flip** — updates the row `WHERE source = 'grouper'` and asserts exactly one
   row moved. `changed_at` is left alone; a trigger maintains it. Re-running is
   a no-op rather than a second audit entry.
3. **Verify** — re-reads the marker from the database rather than trusting the
   update's return, and re-checks that the CronJob is still suspended.
4. **Rollback** — puts the marker back to `grouper` so the importer will run
   again.

## Why preflight checks the CronJob

An unsuspended importer past the flip is not merely noise. Every scheduled run
hits the guard and exits nonzero, so the CronJob accumulates failed Jobs and
reads as a service breaking rather than as a guard doing its job.

## What verify deliberately does not do

It does not start an importer Job to watch it refuse. The refusal is driven
entirely by this one row — `RequireGrouperAuthoritative` reads it and nothing
else — so asserting the row is asserting the refusal, and a Job would only test
the same value twice, slower.

Preflight likewise does not re-check the community tag rewrite.
[community-tags](/playbooks/community-tags.md) reports on its own run, and
deciding which stored tag values are still rewritable means the legacy-name and
short-name precedence rules that live in the `community-tags` command. A second
copy here would be a copy that drifts.

## Rolling back

While the DE is still in maintenance this is free: no users have access, so
nothing has been written natively. Afterwards it discards the group changes users
made since the window — the trade this row exists to make explicit.

Redeploy the services first, then re-enable the importer. The other order has the
DE and the importer writing the same rows at the same time.

1. Set `terrain_groups_backend: iplant-groups`, re-run `configure-services`, and
   redeploy the previous terrain, apps, group-propagator, and sonora images.
2. `ansible-playbook -i <inventory> grouper_cutover.yml --tags=rollback`
3. Run `grouper_import.yml` to reconcile the database back to Grouper's state.

The [permissions](/services/permissions.md) service is the awkward one: its
Grouper-backed code path was deleted rather than toggled, so rolling it back
means redeploying its previous image. That is why its `grouperdb` config section
has to stay in the deployed config until the rollback window closes. Left on the
new image while the rest of the DE runs against Grouper, it needs the
`grouper-import` CronJob unsuspended — permission checks read group data from the
database, and without scheduled imports every change made through Grouper-backed
terrain is invisible until the next import.

## Settings

| Setting | Default | Purpose |
| ------- | ------- | ------- |
| `grouper_cutover_changed_by` | `$USER` | Recorded as who flipped the marker; the column rejects whitespace, so preflight fails on an empty value |
| `grouper_cutover_note` | dated cutover note | Stored alongside the flip |
| `grouper_cutover_rollback_note` | dated rollback note | Stored alongside a rollback |
| `grouper_cutover_required_deployments` | `groups`, `permissions` | Must have available replicas before the flip |

# Citations

[1] `ansible/grouper_cutover.yml` — the playbook.
[2] `ansible/roles/grouper_cutover/` — role tasks and defaults.
[3] [grouper-import](/playbooks/grouper-import.md) — puts the rows in place.
[4] [community-tags](/playbooks/community-tags.md) — the tag rewrite that must precede the flip.
[5] [Grouper](/infrastructure/grouper.md) — the store being retired.
[6] [groups](/services/groups.md) and [permissions](/services/permissions.md) — the services that read the new schema.
