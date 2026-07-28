# appei

Export a Discovery Environment app and its tools as a JSON bundle, and import
that bundle into another DE instance, using only the Terrain API. Useful for
copying public apps between deployments (e.g. production → sw-cacti).

Requires [uv](https://docs.astral.sh/uv/). Run every command from this
directory (or pass `--project scripts/appei` to `uv run`).

## Usage

Log in to each DE instance involved. The password comes from `--password`,
the `APPEI_PASSWORD` environment variable, or an interactive prompt; the
account must be in Terrain's admin groups (`terrain.authz.allowed-groups`)
for the export and import endpoints to work. Tokens are cached per server
under `~/.config/cyverse/discoenv/appei/`.

```console
uv run appei login --server de.cyverse.org --username admin_user
uv run appei login --server de.sw-cacti.example.org --username admin_user
```

Find the app to copy, export it from the source, and import it into the
target:

```console
uv run appei list --server de.cyverse.org
uv run appei export --server de.cyverse.org --id <app-uuid> --output cat-app.json
uv run appei import --server de.sw-cacti.example.org --input cat-app.json
```

Exporting a private app works too: the job-view endpoint requires read
permission on the app itself (admin group membership isn't enough), so on a
403 appei temporarily shares the app with the logged-in admin via the admin
sharing endpoint, retries, and removes the share again afterward.

Importing is idempotent: tools and apps already present on the target
(matched by name and version) are reused instead of recreated. Soft-deleted
apps and tools don't count as present — the admin listings still return them,
but they can't be reused, so matching one would make the import a silent
no-op. A fresh import creates the tools first, rewrites the app's tool
references to the new tool IDs, and creates the app. Tools go through the
private tool route, so they belong to the importing admin; that route forces
`restricted`, `network_mode` and the resource limits to the target's
configured defaults, and rejects the `container_devices`, `container_volumes`
and `container_volumes_from` settings. A tool that populates any of those
fails the import with a message naming them — pass `--public-tool` to create the
tools through the admin route instead, which makes them public DE-wide and is
logged as a warning. The imported app and tools stay private to the
importing admin by default; pass `--publish` to make the app public, or
`--feature` to publish it and mark it as featured. Publishing also removes
the app's beta AVU, and apps exported without documentation are published
with empty documentation, since the DE refuses to publish an app that has
none.

The Docker images referenced by the tools are not copied; they must be
pullable from the target cluster.

`uv run appei shred-app --server <server> --id <app-uuid>` permanently deletes
an app, optionally qualified by `--system-id` (default `de`). Deleting an app
in the UI only sets its `deleted` flag; the row and its tool reference
survive, which keeps the tool from being deleted. Shredding removes the row
outright. It cannot be undone — the exported bundle is the only remaining
copy.

`uv run appei delete-tool --server <server> --id <tool-uuid>` deletes a tool.
Terrain refuses while any app still uses it, and a soft-deleted app counts, so
shred the app first. There is no way to make a public tool private again — the
API has a publish route and no inverse — so delete and re-import is the only
path back.

`uv run appei logout --server <server>` deletes a cached token.

## Development

```console
uv run pytest
uv run ruff check .
uv run ruff format .
```
