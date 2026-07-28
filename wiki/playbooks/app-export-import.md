---
type: Runbook
title: Copying Apps Between DE Instances
description: Using the appei tool to export an app and its tools from one DE as a JSON bundle and import them into another via the Terrain API.
resource: /scripts/appei
tags: [apps, tools, terrain, migration, appei]
timestamp: 2026-07-28T00:00:00Z
---

# Copying Apps Between DE Instances

`scripts/appei/` is a uv-managed Python CLI that copies a Discovery
Environment app, together with the tool(s) it runs, from one DE deployment to
another using only Terrain API endpoints — no service changes or database
access required. The intermediate format is a single JSON bundle, so exports
can be reviewed or kept in version control before importing.

## How it works

Terrain's create-request schemas are derived from its read schemas, which
makes a client-side round-trip possible:

* **Export** merges `GET /terrain/admin/apps/{system-id}/{id}/details`,
  `GET /terrain/apps/{system-id}/{id}`, and, for each referenced tool,
  `GET /terrain/admin/tools/{id}` (which includes the container and image
  definitions plus implementation test data) into one bundle. The job-view
  endpoint checks the caller's own app permissions (admin group membership
  isn't enough), so for a private app the export temporarily shares the app
  with the logged-in admin via `POST /terrain/admin/apps/sharing`, retries,
  and removes the share afterward.
* **Import** creates the tools first with `POST /terrain/tools`, rewrites the
  app's tool references to the newly assigned UUIDs (apps reference tools by
  UUID, which is instance-specific), strips the other source-side IDs and
  listing-only fields, then creates the app with
  `POST /terrain/apps/{system-id}`. The app and tools stay private to the
  importing admin by default; `--publish` makes the app public and removes
  its beta AVU, and `--feature` additionally blesses it as a featured app.
  `--public-tool` switches tool creation to `POST /terrain/admin/tools`, which adds
  them DE-wide as public — needed only for tools carrying the admin-only
  container settings, and warned about when used.

Imports are idempotent: tools and apps that already exist on the target
(matched by name and version) are reused rather than recreated, so a failed
run can be retried. Soft-deleted entries are skipped when matching — the admin
listings still return them, and treating one as "already exists" turned an
import into a silent no-op that could never bring the app back.

* **Shred-app** permanently removes an app with
  `POST /terrain/admin/apps/shredder`. This is not the same as deleting an app
  in the UI, which only sets the `deleted` flag: the row (and its tool
  reference) survives, so the tool it used still cannot be deleted. Shredding
  drops the row outright and releases that reference.
* **Delete-tool** removes a tool with
  `DELETE /terrain/admin/tools/{tool-id}`. Terrain refuses while any app still
  uses the tool, and a soft-deleted app counts toward that check, so the app
  has to be shredded first.

## Running it

Requires uv and an account in Terrain's admin groups
(`terrain.authz.allowed-groups`) on both instances. From `scripts/appei/`:

```
uv run appei login --server <source-fqdn> --username <admin>
uv run appei login --server <target-fqdn> --username <admin>
uv run appei list --server <source-fqdn>
uv run appei export --server <source-fqdn> --id <app-uuid> -o app.json
uv run appei import --server <target-fqdn> -i app.json
uv run appei shred-app --server <target-fqdn> --id <app-uuid>
uv run appei delete-tool --server <target-fqdn> --id <tool-uuid>
```

`shred-app` takes `--id` and an optional `--system-id` (default `de`). It is
irreversible — the app row is removed from the database, so the bundle is the
only remaining copy of the definition. `delete-tool` takes just `--id`; run it
after `shred-app` when retiring an app and its tool together, since the tool
delete fails while any app still references it.

The login password comes from `--password`, `$APPEI_PASSWORD`, or an
interactive prompt; tokens are cached per server under
`~/.config/cyverse/discoenv/appei/`. `appei logout --server <fqdn>` removes a
cached token.

## Caveats

* The Docker images referenced by the tools are not copied — they must be
  pullable from the target cluster (see [Harbor](/infrastructure/harbor.md)).
* Only the exported version of the app is copied; other versions of a
  multi-version app are not.
* Categorization, ratings, and other listing metadata are not carried over;
  even with `--publish` the app arrives uncategorized.
* An app exported without documentation is published (with `--publish`) with
  empty documentation (the DE refuses to publish an app that has none); add
  real documentation on the target afterward if it matters.
* Publishing is one-way. There is no unpublish route for a tool — the API has
  `POST /terrain/admin/tools/{id}/publish` and no inverse — so making a public
  tool private again means deleting and recreating it. Deleting a tool
  requires that no app uses it, and a *soft-deleted* app still counts, so the
  app has to be shredded first.
* The private tool route applies the target's own defaults for `restricted`,
  `container.network_mode` and the CPU/memory/time limits, so an imported
  tool can differ from the source in those fields. Only `--public-tool`
  preserves them verbatim.

# Citations

* `scripts/appei/README.md` — usage and development commands.
* `scripts/appei/src/appei/` — CLI, Terrain client, export/import logic.
