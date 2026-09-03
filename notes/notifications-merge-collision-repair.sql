-- Repair the duplicate notification user rows created by a half-completed
-- cutover, so notifications_db_merge.yml can be re-run.
--
-- Run against the STANDALONE notifications database -- NOT the `de` database,
-- where the "@domain" suffix is the correct storage format and stripping it
-- would corrupt every user row. The guard below refuses to run in the wrong
-- place.
--
-- DRY RUN BY DEFAULT. Everything runs in one transaction and reports what it
-- changed; the transaction is rolled back unless you pass -v apply=1.
--
--   dry run:  psql -h <host> -U <user> -d notifications -f notifications-merge-collision-repair.sql
--   apply:    psql -h <host> -U <user> -d notifications -v apply=1 -f notifications-merge-collision-repair.sql
--
-- Why the duplicates exist: the notifications service ships username
-- qualification and the repoint onto the DE database in the same deploy. If
-- the qualification half lands alone, the service keeps writing to the
-- standalone database -- whose users rows are bare -- and its lookup for
-- "jdoe@<uid_domain>" misses the existing "jdoe" row, so it creates a second
-- one. The person's history then splits across two rows, and both spellings
-- qualify to the same DE username, which trips the colliding_users check in
-- the merge role's verify.sql.
--
-- This script consolidates each such pair back onto the bare row. Run it after
-- the service has actually been repointed, otherwise it will just recreate the
-- duplicates on the next notification.
--
-- Deliberately NOT touched: rows whose username is an address at some other
-- domain, e.g. "stephen.wright@utoronto.ca". Those are long-standing rows, not
-- artifacts of the bad deploy, and the merge already resolves them correctly by
-- truncating at the first '@'.

\pset border 2
\timing on
\set ON_ERROR_STOP on

\if :{?apply}
\else
  \set apply 0
\endif

\if :{?uid_domain}
\else
  \set uid_domain iplantcollaborative.org
\endif

-- Abort if this isn't the standalone notifications database. Both it and the
-- DE database have a public.users table, and this script would strip the
-- suffix from every DE user if pointed at the wrong one.
DO $$
BEGIN
  IF to_regclass('public.notifications') IS NULL
     OR to_regclass('public.notification_types') IS NULL THEN
    RAISE EXCEPTION
      'No notifications schema here (current_database() = %). Re-run with -d notifications.',
      current_database();
  END IF;

  IF to_regclass('public.jobs') IS NOT NULL OR to_regclass('public.apps') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the DE database (current_database() = %), where qualified usernames are correct. Refusing to run.',
      current_database();
  END IF;
END
$$;

BEGIN;

-- Each qualified row the bad deploy created, paired with the bare row that
-- already held the person's history.
CREATE TEMPORARY TABLE dup_pair ON COMMIT DROP AS
SELECT dup.id       AS dup_id,
       dup.username AS dup_username,
       bare.id      AS bare_id,
       bare.username AS bare_username
FROM users dup
JOIN users bare
  ON bare.username = regexp_replace(dup.username, '@.*$', '')
WHERE dup.username = regexp_replace(dup.username, '@.*$', '') || '@' || :'uid_domain';

\echo ''
\echo '=== Plan: duplicate rows to fold back onto the bare user ==='
SELECT p.dup_username,
       (SELECT count(*) FROM notifications n WHERE n.user_id = p.dup_id)  AS moving,
       p.bare_username,
       (SELECT count(*) FROM notifications n WHERE n.user_id = p.bare_id) AS already_there
FROM dup_pair p
ORDER BY p.dup_username;

\echo ''
\echo '=== Left alone: qualified rows at other domains, and rows with no bare counterpart ==='
SELECT u.username,
       (SELECT count(*) FROM notifications n WHERE n.user_id = u.id) AS notifications
FROM users u
WHERE u.username LIKE '%@%'
  AND u.username NOT LIKE '@grouper-%'
  AND u.id NOT IN (SELECT dup_id FROM dup_pair)
ORDER BY u.username;

\echo ''
\echo '=== Step 1: repoint notifications onto the bare user ==='
WITH moved AS (
  UPDATE notifications n
     SET user_id = p.bare_id
    FROM dup_pair p
   WHERE n.user_id = p.dup_id
  RETURNING p.dup_username
)
SELECT dup_username, count(*) AS notifications_moved
FROM moved GROUP BY dup_username ORDER BY dup_username;

\echo ''
\echo '=== Step 2: delete the emptied duplicate user rows ==='
WITH gone AS (
  DELETE FROM users u
   WHERE u.id IN (SELECT dup_id FROM dup_pair)
     AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.user_id = u.id)
  RETURNING u.username
)
SELECT username AS deleted_user FROM gone ORDER BY username;

\echo ''
\echo '=== After: collisions the merge would still see (must be empty) ==='
SELECT de_username, count(*) AS staged_accounts,
       string_agg(username, ' + ' ORDER BY username) AS spellings
FROM (
  SELECT id, username,
         regexp_replace(username, '@.*$', '') || '@' || :'uid_domain' AS de_username
  FROM users
  WHERE username NOT LIKE '@grouper-%'
) s
GROUP BY de_username HAVING count(*) > 1
ORDER BY de_username;

\if :apply
COMMIT;
\echo ''
\echo '*** APPLIED AND COMMITTED ***'
\echo '*** Now re-run notifications_db_merge.yml to sweep the gap rows into the DE database. ***'
\else
ROLLBACK;
\echo ''
\echo '*** DRY RUN -- everything above was rolled back. ***'
\echo '*** Re-run with -v apply=1 to apply it.          ***'
\endif
