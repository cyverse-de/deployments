---
type: Runbook
title: Copying Apps Between DE Instances
description: Using the appei tool to export an app and its tools from one DE as a JSON bundle and import them into another via the Terrain API.
resource: /scripts/appei
tags: [apps, tools, terrain, migration, appei]
timestamp: 2026-07-21T00:00:00Z
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
* **Import** creates the tools first with `POST /terrain/admin/tools`,
  rewrites the app's tool references to the newly assigned UUIDs (apps
  reference tools by UUID, which is instance-specific), strips the other
  source-side IDs and listing-only fields, then creates the app with
  `POST /terrain/apps/{system-id}`. The app and tools stay private to the
  importing admin by default; `--publish` makes the app public and removes
  its beta AVU, and `--feature` additionally blesses it as a featured app.

Imports are idempotent: tools and apps that already exist on the target
(matched by name and version) are reused rather than recreated, so a failed
run can be retried.

## Running it

Requires uv and an account in Terrain's admin groups
(`terrain.authz.allowed-groups`) on both instances. From `scripts/appei/`:

```
uv run appei login --server <source-fqdn> --username <admin>
uv run appei login --server <target-fqdn> --username <admin>
uv run appei list --server <source-fqdn>
uv run appei export --server <source-fqdn> --id <app-uuid> -o app.json
uv run appei import --server <target-fqdn> -i app.json
```

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

# Citations

* `scripts/appei/README.md` — usage and development commands.
* `scripts/appei/src/appei/` — CLI, Terrain client, export/import logic.
