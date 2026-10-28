-- Repair the duplicate QMS user rows found by qms-user-blast-radius.sql.
--
-- DRY RUN BY DEFAULT. Every step runs inside one transaction and reports what it
-- changed; the transaction is rolled back unless you pass -v apply=1.
--
--   dry run:  psql -h <host> -U <user> -d qms -f qms-user-repair.sql
--   apply:    psql -h <host> -U <user> -d qms -v apply=1 -f qms-user-repair.sql
--
-- What it does:
--   1. Repoints subscriptions from each "name@domain" row onto the "name" row,
--      consolidating a person's history under one user.
--   2. Strips the suffix from orphaned rows that have no bare counterpart.
--   3. Trims a username carrying stray whitespace, if that doesn't collide.
--
-- What it deliberately does NOT do: delete the emptied suffixed user rows.
-- updates.user_id is a FOREIGN KEY with no ON DELETE action and no index, so
-- each DELETE forces a sequential scan of the ~340M-row updates table to check
-- for referencing rows. See the notes at the bottom before attempting it.
--
-- Pairs where the suffixed row holds an ACTIVE subscription are skipped and
-- reported: consolidating those could leave a user with two active
-- subscriptions, which is a decision for a person, not a script.

\pset border 2
\timing on
\set ON_ERROR_STOP on

\if :{?apply}
\else
  \set apply 0
\endif

DO $$
BEGIN
  IF to_regclass('public.subscriptions') IS NULL OR to_regclass('public.plan_rates') IS NULL THEN
    RAISE EXCEPTION
      'This is not the QMS database (current_database() = %). Re-run with -d qms.',
      current_database();
  END IF;
END
$$;

BEGIN;

-- Suffixed rows and their bare counterparts, as at this moment.
CREATE TEMP TABLE sfx AS
  SELECT u.id, u.username, split_part(u.username, '@', 1) AS bare_name
    FROM users u WHERE u.username LIKE '%@%';
CREATE INDEX ON sfx (id);

CREATE TEMP TABLE bare AS
  SELECT b.id, b.username FROM users b
   WHERE b.username NOT LIKE '%@%' AND b.username <> ''
     AND EXISTS (SELECT 1 FROM sfx s WHERE s.bare_name = b.username);
CREATE INDEX ON bare (id);
ANALYZE sfx; ANALYZE bare;

-- Active-subscription counts for just those users.
CREATE TEMP TABLE act AS
  SELECT u.id, count(s.id) FILTER (
           WHERE s.effective_start_date <= CURRENT_TIMESTAMP
             AND (s.effective_end_date IS NULL OR s.effective_end_date >= CURRENT_TIMESTAMP)
         ) AS active_subs
    FROM (SELECT id FROM sfx UNION ALL SELECT id FROM bare) u
    LEFT JOIN subscriptions s ON s.user_id = u.id
   GROUP BY u.id;
CREATE INDEX ON act (id);
ANALYZE act;

-- The pairs this script will consolidate, and the ones it refuses to touch.
CREATE TEMP TABLE merge_map AS
  SELECT s.id AS sfx_id, s.username AS sfx_name, b.id AS bare_id, b.username AS bare_name,
         sa.active_subs AS sfx_active, ba.active_subs AS bare_active
    FROM sfx s
    JOIN bare b ON b.username = s.bare_name
    JOIN act sa ON sa.id = s.id
    JOIN act ba ON ba.id = b.id;
ANALYZE merge_map;

\echo ''
\echo '=== Plan ==='
SELECT count(*) FILTER (WHERE sfx_active = 0)                        AS pairs_to_consolidate,
       count(*) FILTER (WHERE sfx_active > 0)                        AS pairs_skipped_suffixed_active,
       (SELECT count(*) FROM sfx s
         WHERE NOT EXISTS (SELECT 1 FROM merge_map m WHERE m.sfx_id = s.id)) AS orphans_to_rename,
       (SELECT count(*) FROM users WHERE username <> btrim(username))  AS whitespace_rows
  FROM merge_map;

\echo ''
\echo '=== Skipped: suffixed row holds an active subscription (needs a human) ==='
SELECT sfx_name, bare_name, sfx_active, bare_active
  FROM merge_map WHERE sfx_active > 0 ORDER BY sfx_name LIMIT 50;

\echo ''
\echo '=== Step 1: repoint subscriptions onto the bare user ==='
WITH moved AS (
  UPDATE subscriptions s SET user_id = m.bare_id
    FROM merge_map m
   WHERE s.user_id = m.sfx_id AND m.sfx_active = 0
  RETURNING 1
)
SELECT count(*) AS subscriptions_repointed FROM moved;

\echo ''
\echo '=== Step 2: strip the suffix from orphaned rows (no bare counterpart) ==='
WITH renamed AS (
  UPDATE users u SET username = split_part(u.username, '@', 1)
   WHERE u.id IN (SELECT s.id FROM sfx s
                   WHERE NOT EXISTS (SELECT 1 FROM merge_map m WHERE m.sfx_id = s.id))
     AND NOT EXISTS (SELECT 1 FROM users x WHERE x.username = split_part(u.username, '@', 1))
  RETURNING 1
)
SELECT count(*) AS orphans_renamed FROM renamed;

\echo ''
\echo '=== Step 3: trim whitespace-padded usernames where no collision results ==='
WITH trimmed AS (
  UPDATE users u SET username = btrim(u.username)
   WHERE u.username <> btrim(u.username)
     AND NOT EXISTS (SELECT 1 FROM users x WHERE x.username = btrim(u.username))
  RETURNING 1
)
SELECT count(*) AS usernames_trimmed FROM trimmed;
SELECT id, '['||username||']' AS still_padded_collides
  FROM users u WHERE u.username <> btrim(u.username);

\echo ''
\echo '=== After: suffixed rows still carrying subscriptions ==='
SELECT count(DISTINCT u.id) AS suffixed_users_with_subs
  FROM users u JOIN subscriptions sub ON sub.user_id = u.id
 WHERE u.username LIKE '%@%';

\if :apply
COMMIT;
\echo ''
\echo '*** APPLIED AND COMMITTED ***'
\else
ROLLBACK;
\echo ''
\echo '*** DRY RUN -- everything above was rolled back. ***'
\echo '*** Re-run with -v apply=1 to apply it.          ***'
\endif

-- ---------------------------------------------------------------------------
-- Deleting the emptied suffixed user rows, if you want them gone.
--
-- Not part of this script because updates.user_id is a FOREIGN KEY with no
-- ON DELETE action and no supporting index, so every DELETE scans ~340M rows to
-- check for referencing updates. Build the index first -- it is worth having
-- permanently regardless, since that FK is unsupported today:
--
--   CREATE INDEX CONCURRENTLY updates_user_id_index ON updates (user_id);
--
-- Then find out whether these users have any audit rows at all (one scan):
--
--   SELECT count(DISTINCT up.user_id)
--     FROM updates up
--     JOIN users u ON u.id = up.user_id
--    WHERE u.username LIKE '%@%';
--
-- If that is zero, the deletes are cheap once the index exists. If not, repoint
-- those rows the same way step 1 repoints subscriptions, then delete.
