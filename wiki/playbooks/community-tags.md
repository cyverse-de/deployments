---
type: Runbook
title: Rewriting App Community Tags
description: Running the community-tags migration, which changes the community tag on an app from the community's name to its ID.
resource: /ansible/community_tags.yml
tags: [communities, apps, metadata, migration, groups]
timestamp: 2026-09-03T00:00:00Z
---

An app's community tag is an AVU on the app, stored under
`apps_communities_attr` (`cyverse-community`). Its value used to be the
community's **name** — in [Grouper](/infrastructure/grouper.md), the full
colon-delimited path — composed by the browser and stored verbatim.

A name is not a stable identifier. Renaming a community left every app tagged
with the old name out of its own listing, with nothing raised anywhere. That is
how production came to hold 17 tag values naming communities that no longer
exist, across 48 apps.

`community-tags` rewrites each value to the community's ID. It ships in the
[groups](/services/groups.md) image beside the
[Grouper importer](/playbooks/grouper-import.md), because it runs once as a Job
against the same databases.

## Running it

```
ansible-playbook -i $INVENTORY community_tags.yml -e dry_run=true
ansible-playbook -i $INVENTORY community_tags.yml
```

The playbook runs the Job, waits, prints the report, and fails if the Job did
not succeed. Credentials go in through a Secret as `GROUPS_TAGS_*` environment
variables, so they never appear on a command line.

**Run it once, after the group import and before apps starts writing tags of its
own.** The importer has to have run first, because the mapping comes from the
`legacy_name` it records on every group it writes.

## What the report means

- **`distinct tag values: N, of which M rewritten`** — how many values were
  found and how many resolved to a community.
- **`tag rows: N rewritten, M removed as duplicates, K units normalized`** — a
  rewrite collides with `avus_unique` when an app already carries both the old
  and new forms, so the row being migrated is dropped; the tag it expresses is
  already present. Units are set to `''` on the rewritten rows, because apps
  writes and deletes community tags with an empty unit and the metadata deleter
  matches the exact triple — a row keeping any other unit would survive every
  removal as a silent no-op. Production holds three such rows, hand-tagged with
  file formats onto the Integrated Genome Browser community.
- **`tag values naming no community`** — the orphans. **This is the list worth
  reading.** Those apps will not appear in any collection, and they did not
  before the migration either. They are reported and left exactly as they are:
  they resolve to nothing, and deleting the rows would discard the only
  remaining record of what an app was once tagged with.

Running it again is a no-op — a value that is already a community ID is left
alone — so a second run reporting `0 rewritten` is the expected end state.

## Where it sits in the cutover

It runs after [grouper-import](/playbooks/grouper-import.md), whose recorded
`legacy_name` values are the mapping, and before the marker flip in
[Cutting Group Management Over from Grouper](/playbooks/grouper-cutover.md) —
which is to say before the new apps image starts writing ID-based tags of its
own.

## Why it is a command and not a migration

The mapping spans two databases. Community identity lives in the `permissions`
schema of the DE database; the tags live in the metadata service's own database
(`metadata_db_name`). No migration in either can see both.

## Keeping the attribute in step

`apps_communities_attr` is rendered into both apps' config and this Job's
environment. They must agree: pointed at the wrong attribute, the migration
finds nothing and reports a clean run, which looks exactly like success.

# Citations

[1] `ansible/community_tags.yml` — the Job, its secret, the wait, and the report.
[2] `ansible/roles/common/defaults/main.yml` — `apps_communities_attr`.
[3] `ansible/roles/services/apps/templates/apps.properties.j2` — the same attribute, rendered for apps.
