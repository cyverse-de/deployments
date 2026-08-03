# Community App Tags: Scope Note

Written 2026-07-27, during the Grouper removal work. Measured against production
(`grainger.cyverse.org`) unless noted.

## The problem in one sentence

The identifier that says "this app belongs to this community" is a Grouper group
path, it is minted by the **browser**, and it is stored as an opaque string in the
metadata database — so removing Grouper touches Sonora, terrain, apps, and the
metadata data itself, none of which own the identifier.

## How the value is produced today

```
Grouper group.display_name          "iplant:de:prod:communities:AgBase"
  -> iplant-groups                  (passed through)
  -> terrain community listing      (display_name untouched)
  -> Sonora                         collection.display_name
                                    src/components/collections/form/index.js:278
  -> Sonora writes the AVU          value: fullName
                                    src/serviceFacades/groups.js:559-565
  -> terrain POST /apps/:id/communities   (body forwarded verbatim)
  -> apps                           forwards over HTTP to the metadata service
                                    src/apps/clients/metadata.clj:22-24
  -> metadata service               writes avus, attribute 'cyverse-community'
```

No service qualifies, validates, or normalizes the string. The metadata service is
the one component treating it as opaque correctly — uninterpreted attribute/value
pairs are its whole job. The problem is that everyone upstream does the same, so
the identifier has no owner and nothing has ever caught it drifting.

Note that apps reaches metadata only over HTTP (`apps.metadata.base-url`,
`http://metadata:60000`); it has no database access to the AVU tables.

## What the data looks like

| Measure | Value |
| --- | --- |
| Community AVU rows | 182 |
| Apps carrying a community tag | 121 |
| Distinct tag values | 51 — **all** of the form `iplant:de:prod:communities:<name>` |
| Communities in Grouper | 52 |
| Communities never tagged | 18 |
| **Tag values naming a community that no longer exists** | **17 (66 rows, 48 apps)** |

40% of tagged apps carry a tag that resolves to nothing. These are inert rather
than broken: an orphan tag simply never matches a community listing. Whether they
came from community deletions (unguarded) or renames that slipped past the
`force-rename` check cannot be determined from the data.

## Why this blocks the Grouper removal

The tag value is `display_name`, which in Grouper happens to equal the full colon
path. In the replacement store `display_name` is an ordinary human-friendly name
and may be null.

**The moment terrain serves communities from the new store, Sonora begins writing
a different value than it does today — silently, with no error anywhere, creating
new orphans by exactly the mechanism that produced the existing 17.**

That is true whether or not we deliberately change the format. There is no
"leave it alone" option.

## Proposed fix

Switch the tag value to the group's **ID** — stable, opaque, and immune to
renames, which is what the current design lacks.

1. **Data migration** — rewrite the 116 resolvable rows to group IDs. This lands in
   the metadata service's own database (the standalone `metadata` database), not
   `de-database`. The `metadata` schema inside `de` exists from de-database
   migration `000025` but is empty in both QA and production, and the deployed
   service still points at the standalone database (`metadata_db_name: metadata`).
2. **Orphans** — leave the 66 unresolvable rows as-is. Verified safe: no code path
   enumerates an app's stored community AVUs and requires each to resolve.
   `filter-app-ids-by-community` is an exact-value match; the admin-validation and
   publish paths only read AVUs from the request body. Clean them up later, once
   we're sure nobody misses them.
3. **Move the association behind a semantic API** so the browser stops knowing the
   storage format at all — see below.
4. **terrain** — `retag.clj`, rename-blocking, and the `retag-apps`/`force-rename`
   flags are deleted. Renaming a community becomes a single row update instead of
   a cross-service rewrite that can half-fail.

## The API change

The endpoint is already community-specific — `POST /apps/:app-id/communities`, and
`add-app-to-communities` discards everything in the payload except the community
AVUs (`filter-community-avus`, rejecting with "No community metadata found in
request"). The AVU envelope is ceremony. Replace it:

```
POST   /apps/:app-id/communities              {"community_ids": ["<id>", ...]}
DELETE /apps/:app-id/communities/:community-id
```

apps then owns the storage format outright, and the next change to it — including
moving communities off AVUs entirely, which the permissions/groups merge may want
— is a one-service change rather than a four-service one.

This is contained. `AppCategoryMetadataAddRequest` / `AppCategoryMetadataDeleteRequest`,
despite their names, are referenced only by the community routes in terrain
(`routes/apps/communities.clj:30,37`) and apps (`routes/apps/communities.clj:20,29,41,56`).
Nothing in app-category metadata uses them. They live in `common-swagger-api`, so
add a new community schema there rather than mutating those.

It also improves the transition. Rather than having apps sniff whether a value is a
32-hex ID or a colon path — fragile heuristics — it accepts two documented request
shapes and drops the old one once no stale browser bundles remain. Explicit
contract versioning beats format detection.

## Open items

- **The admin raw-AVU editor bypasses all of this.** `adminSetAppAVUs`
  (`sonora/src/serviceFacades/apps.js:435`) sets an app's full AVU list, community
  tags included. It round-trips stored values rather than minting new ones, but it
  can write arbitrary community values. Decide whether to filter community AVUs out
  of that path or accept it as a deliberate admin escape hatch.
- **The read side is not covered by a semantic write endpoint.**
  `GET /api/apps/communities/:community-id/apps` still passes an identifier that
  must match the stored format, so apps needs name-or-ID resolution there
  regardless.
- Verified clean: the publish path is **not** a second minting site. Sonora's
  publish request body carries no `avus` key
  (`sonora/src/components/apps/PublishAppDialog.js:187-193`), so
  `publish-app-metadata`'s community handling never fires from the DE UI.

## Impact on the cutover

Sonora joins terrain, apps, and group-propagator in the coordinated window. It was
not previously accounted for. The permissions service still cuts over first and
alone.

## Decisions needed

- Confirm the switch to group IDs.
- Confirm deferring orphan cleanup rather than deleting or double-handling now.
- Confirm Sonora joining the cutover window, and who owns that change.
