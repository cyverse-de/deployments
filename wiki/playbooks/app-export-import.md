---
type: Runbook
title: Copying Apps Between DE Instances
description: Using the appei tool to export an app and its tools from one DE as a JSON bundle and import them into another via the Terrain API, and the de_apps role that imports a default set into a new deployment.
resource: /scripts/appei
tags: [apps, tools, terrain, migration, appei]
timestamp: 2026-07-31T12:00:00Z
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

## Importing a default set with `import_apps.yml`

A freshly deployed DE has nothing runnable in it. The `de_apps` role wraps
`appei` so a deployment can be given a starting set of apps without anyone
remembering the commands:

```
ansible-playbook -i <inventory> import_apps.yml
```

The bundles it imports live in `ansible/roles/de_apps/files/apps/`, and
`de_apps_bundles` lists which of them to import and how public each should be.
The default set is `DE Word Count` and `CloudShell` — one batch app and one
VICE app, so both execution paths can be exercised — published, plus
`portal-delete-user`, which deletes portal accounts and so stays private to the
importing admin. `de_apps_bundle_dir` points the role at a different directory
when an inventory ships its own bundles.

The role authenticates as `portal_bootstrap_user` against `de_hostname`, so it
has to run **after** [bootstrap_portal_admin.yml](/playbooks/bootstrap-portal-admin.md):
creating an app requires an account that already has a DE workspace, and that
playbook is what provides one. Re-running is safe — appei reuses what is
already on the target, and the role reports `changed` only when something was
actually created.

Where the DE's certificate chains to a private CA, `de_apps_ca_bundle` names
the certificate for `REQUESTS_CA_BUNDLE`; it defaults to the same file the
services get and is unset in deployments that don't use one. Without it appei
fails to verify the DE's certificate, since `requests` reads a bundle of its
own rather than the system trust store.

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

* Apps seeded by the `de-database` migrations (`DE Word Count` at version
  `Unversioned`, `Python 2.7`) have no rows in the permissions service, so they
  appear in no listing. An imported app of the same name does not collide with
  them, and only the imported one is visible.

* **A bundle cannot be re-imported after editing it.** The exported parameter
  and argument IDs are carried verbatim, so importing an edited copy — even
  under a new app version — fails with
  `duplicate key value violates unique constraint "parameter_values_pkey"`,
  which names a column rather than the bundle. Stripping every `id` and
  `version_id` from the bundle lets Terrain assign new ones, which works.
  Deleting the app first does not: `DELETE /apps/{system-id}/{id}` is a soft
  delete (and returns 403 for a published app — the admin endpoint is
  `DELETE /admin/apps/{system-id}/{id}`), and the deleted app still appears in
  the admin listing that `appei` matches against, so the next import reports it
  as already existing and skips it. Between them, editing
  `roles/de_apps/files/apps/*.json` only takes effect on a DE that has never
  imported that app.

* **A `FileOutput` parameter is a command-line argument, not a redirect.** With
  an empty `name` it is appended positionally, so a tool that writes to stdout
  receives the output filename as an extra input. `DE Word Count` shipped that
  way and could not succeed: the step ran
  `wc <input> wc.out`, GNU `wc` reported `wc.out: No such file or directory`
  and exited 1, and the analysis failed at the exit handler with the unrelated
  message `sending final status`. The parameter was removed; the counts land in
  `logs/step-0.stdout.log` in the output folder, which porklock uploads with
  the rest. A tool that should produce a named file needs the redirect in the
  tool's own entrypoint, not a `FileOutput` parameter.

# Citations

* `scripts/appei/README.md` — usage and development commands.
* `scripts/appei/src/appei/` — CLI, Terrain client, export/import logic.
* `ansible/import_apps.yml`, `ansible/roles/de_apps/` — the default app set and
  how it is imported.
