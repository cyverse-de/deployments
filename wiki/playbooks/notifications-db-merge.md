---
type: Playbook
title: Merging the Notifications Database into DE
description: How notifications_db_merge.yml moves the standalone notifications database into the DE database's public schema, remapping user and notification-type identifiers on the way.
resource: /ansible/notifications_db_merge.yml
tags: [notifications, postgresql, migration, database, de-database]
timestamp: 2026-08-14T00:00:00Z
---

The [notifications](/services/notifications.md) service has always kept its own
database. Its rows are really satellites of the DE database — every analysis
notification carries a `jobs.id` in its JSON payload — but the relationship is
expressed as an opaque string across a database boundary, unenforceable and
unjoinable. `notifications_db_merge.yml` closes that gap by moving the rows
into `public.notifications` in the DE database.

The schema is created by `de-database` migrations `000055` and `000056`; this
playbook moves only the data. A migration cannot reach across databases, and
neither `dblink` nor `postgres_fdw` is installed on the
[PostgreSQL](/infrastructure/postgresql.md) DBMS.

```bash
ansible-playbook -i <inventory> notifications_db_merge.yml
```

## Precondition: the service must qualify usernames first

**Run this only after the notifications service has been changed to append
`uid_domain` to usernames.** The standalone database stores bare usernames
(`jdoe`); `public.users` stores qualified ones (`jdoe@iplantcollaborative.org`).
The service writes table names unqualified and normalizes nothing, and its user
upsert is `INSERT INTO users (username) ... ON CONFLICT (username) DO UPDATE`.
Pointed at the DE database while still writing bare usernames, it will insert
them into the `users` table that apps, analyses, and requests all key off.

The playbook cannot check this — it is a property of the running service, not
of the database. It is the one step that has to be sequenced by hand.

## What the two identifiers do

Both keys have to be rewritten, because neither survives the move:

- **Users.** No account shares an id between the two databases, so every
  `user_id` is remapped by username, qualified the way every other DE service
  qualifies one — `apps.user/append-username-suffix`, which **truncates at the
  first `@` before appending** rather than appending outright:

  ```clojure
  (str (string/replace username #"@.*$" "") "@" (uid-domain))
  ```

  That distinction matters for the handful of notification accounts whose name
  is already an address. `stephen.wright@utoronto.ca` resolves to
  `stephen.wright@iplantcollaborative.org` — their real DE account — and not to
  `stephen.wright@utoronto.ca@iplantcollaborative.org`, which also exists in
  `public.users` but is a stray nothing else references.

  Where both `name@domain` and the malformed `name@@domain` spellings exist,
  the single-`@` row wins; that is the row the rest of the DE references.
- **Notification types.** The standalone database keys notifications to its own
  `notification_types` rows. Migration `000055` replaced the DE's
  `notification_types` enum with a table seeded by name, so the mapping is by
  name.

Notification ids are preserved. Clients hold them: `outgoing_json` embeds the
id as `message.id`, and the update endpoints address notifications by it.

## The plays

Each is separately tagged (`dump`, `stage`, `load`, `verify`, `cleanup`).

1. **Dump** — refuses to start unless `public.notifications` exists, then
   `pg_dump`s the standalone database to `notifications_db_merge_dump_file`.
   The dump is the rollback artifact, not the load path; the playbook never
   removes it.
2. **Stage** — creates `notifications_db_merge_staging_schema` inside the DE
   database from `files/staging_schema.sql` and streams the rows in with
   `\copy ... TO STDOUT | \copy ... FROM STDIN`. The staging DDL is
   hand-written rather than restored from the dump on purpose: `pg_dump`
   qualifies every object as `public`, and rewriting that to another schema
   means editing a file that also holds the jsonb payloads.
3. **Load** — runs `files/transform.sql`, which creates DE users for staged
   accounts the DE has never seen, resolves the two mappings into temporary
   tables, and inserts. It is idempotent; a second run inserts nothing.
4. **Verify** — runs `files/verify.sql` and fails the play unless every staged
   account and type resolved, no two staged accounts qualify to the same DE
   username, and the loaded count matches the expected count. The collision
   check is there because two accounts merging under one DE user would
   otherwise reconcile perfectly while silently combining two people's
   notification histories; neither environment has one today.
5. **Cleanup** — drops the staging schema unless
   `notifications_db_merge_keep_staging` is set.

## Accounts with no DE counterpart

The notifications service creates a user row on demand for anyone it receives a
notification about, so its user list is **not** a subset of `public.users`. Two
kinds of stranger turn up:

- **Real people** who were notified without ever launching an analysis. The
  transform creates them in `public.users` with the suffix applied.
- **iplant-groups subject IDs**, which terrain sends as the user for team
  notifications. These match `notifications_db_merge_junk_user_pattern`
  (`@grouper-%`), are not people, and are discarded along with their
  notifications. The verify step reports how many went.

## Settings

All in `ansible/roles/notifications_db_merge/defaults/main.yml` except
`uid_domain`, which comes from `ansible/roles/common/defaults/main.yml`.

| Setting | Default | Purpose |
| ------- | ------- | ------- |
| `notifications_db_merge_dump_file` | `./notifications_merge_dump.sql` | Rollback dump location |
| `notifications_db_merge_staging_schema` | `notifications_staging` | Schema the rows land in first; **dropped** by the staging step, so it must not name a real schema |
| `notifications_db_merge_keep_staging` | `false` | Leave staging in place for inspection |
| `notifications_db_merge_junk_user_pattern` | `@grouper-%` | Accounts discarded instead of created |
| `uid_domain` | `iplantcollaborative.org` | Suffix joining bare usernames to `public.users` |

## After the move

The standalone database is left untouched and running. Retire it — along with
the `notifications-db` migration job, the `db_copy_prod` notifications task,
and the `notifications.db.uri` stanza that six service configs carry but never
read — only once the service has been cut over and verified.

# Citations

[1] `ansible/notifications_db_merge.yml` — the playbook.
[2] `ansible/roles/notifications_db_merge/` — role tasks, defaults, and SQL.
[3] [notifications](/services/notifications.md) — the service that owns these rows.
[4] [PostgreSQL](/infrastructure/postgresql.md) — the DBMS and its databases.
