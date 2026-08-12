-- Blast radius of the two QMS username bugs. Read-only; safe to run anywhere.
--
--   1. POST /v1/subscriptions stored usernames verbatim while every other route
--      trimmed the suffix, so one person can hold two `users` rows.
--   2. PUT /users on the subscriptions service blanked the username, creating a
--      row named '' and subscribing it.
--
-- Run against the `qms` database -- NOT the `de` database, which has a users
-- table of its own where the "@domain" suffix is the correct storage format:
--   psql -h <host> -U <user> -d qms -f qms-user-blast-radius.sql
--
-- Every section touches only users and subscriptions, so the run stays fast
-- regardless of how large the usage and audit tables have grown. The 340M-row
-- updates table is never scanned; the commented query at the bottom is the only
-- thing that would touch it, and it is opt-in.

\pset border 2
\timing on
\set ON_ERROR_STOP on

-- Abort immediately if this isn't the QMS schema. Without this the first query
-- still "works" against the de database and reports every DE user as damage.
DO $$
BEGIN
  IF to_regclass('public.subscriptions') IS NULL OR to_regclass('public.plan_rates') IS NULL THEN
    RAISE EXCEPTION
      'This is not the QMS database (current_database() = %). Re-run with -d qms.',
      current_database();
  END IF;
END
$$;

\echo ''
\echo '=== 0. Table sizes (planner estimates, instant) ==='
SELECT relname AS table, to_char(reltuples::bigint, 'FM999,999,999') AS est_rows,
       pg_size_pretty(pg_total_relation_size(oid)) AS size
  FROM pg_class
 WHERE relname IN ('users','subscriptions','usages','quotas','updates','subscription_addons')
   AND relkind = 'r'
 ORDER BY reltuples DESC;

\echo ''
\echo '=== 1. Overall shape ==='
SELECT count(*)                                             AS total_users,
       count(*) FILTER (WHERE username LIKE '%@%')          AS suffixed_rows,
       count(*) FILTER (WHERE username = '')                AS blank_username_rows,
       count(*) FILTER (WHERE username <> btrim(username))  AS whitespace_padded_rows
  FROM users;

-- The affected users: suffixed (or blank) rows and their bare counterparts.
CREATE TEMP TABLE affected AS
  SELECT u.id, u.username, split_part(u.username, '@', 1) AS bare_name, true AS is_suffixed
    FROM users u
   WHERE u.username LIKE '%@%' OR u.username = ''
  UNION ALL
  SELECT b.id, b.username, b.username, false
    FROM users b
   WHERE b.username <> ''
     AND b.username NOT LIKE '%@%'
     AND EXISTS (SELECT 1 FROM users s
                  WHERE s.username LIKE '%@%'
                    AND split_part(s.username, '@', 1) = b.username);
CREATE INDEX ON affected (id);
ANALYZE affected;

-- Subscription counts only. This is one pass over subscriptions, which is the
-- smallest of the child tables and the only one triage needs.
CREATE TEMP TABLE sub_counts AS
SELECT a.id,
       count(s.id) AS subs,
       count(s.id) FILTER (
         WHERE s.effective_start_date <= CURRENT_TIMESTAMP
           AND (s.effective_end_date IS NULL OR s.effective_end_date >= CURRENT_TIMESTAMP)
       ) AS active_subs
  FROM affected a
  LEFT JOIN subscriptions s ON s.user_id = a.id
 GROUP BY a.id;
CREATE INDEX ON sub_counts (id);
ANALYZE sub_counts;

-- Pairs and orphans, with subscription counts attached. Small.
CREATE TEMP TABLE pairs AS
SELECT s.id AS sfx_id, s.username AS suffixed, b.id AS bare_id, b.username AS bare,
       sc.subs AS sfx_subs, sc.active_subs AS sfx_active,
       bc.subs AS bare_subs, bc.active_subs AS bare_active
  FROM affected s
  JOIN sub_counts sc ON sc.id = s.id
  JOIN affected b ON b.username = s.bare_name AND NOT b.is_suffixed
  JOIN sub_counts bc ON bc.id = b.id
 WHERE s.is_suffixed AND s.username <> '';
ANALYZE pairs;

\echo ''
\echo '=== 2. Reconciliation summary (read this first) ==='
SELECT
  (SELECT count(*) FROM pairs)                                              AS duplicate_pairs,
  (SELECT count(*) FROM pairs WHERE sfx_active > 0 AND bare_active > 0)     AS pairs_active_both_sides,
  (SELECT count(*) FROM pairs WHERE sfx_subs = 0)                           AS pairs_suffixed_side_empty,
  (SELECT count(*) FROM affected a JOIN sub_counts sc ON sc.id = a.id
    WHERE a.is_suffixed AND a.username <> ''
      AND NOT EXISTS (SELECT 1 FROM pairs p WHERE p.sfx_id = a.id))         AS orphan_suffixed,
  (SELECT count(*) FROM affected a JOIN sub_counts sc ON sc.id = a.id
    WHERE a.is_suffixed AND a.username <> '' AND sc.subs = 0
      AND NOT EXISTS (SELECT 1 FROM pairs p WHERE p.sfx_id = a.id))         AS orphan_suffixed_empty,
  (SELECT coalesce(sum(sc.subs), 0) FROM affected a JOIN sub_counts sc ON sc.id = a.id
    WHERE a.is_suffixed AND a.username <> '')                               AS subs_on_suffixed_rows,
  (SELECT coalesce(sum(sc.subs), 0) FROM affected a JOIN sub_counts sc ON sc.id = a.id
    WHERE a.username = '')                                                  AS subs_on_blank_row;

\echo ''
\echo '=== 3. What the reconciliation actually involves ==='
\echo '    empty suffixed rows are deletable; the rest need a decision.'
SELECT 'suffixed rows with no subscriptions (deletable)' AS category,
       count(*) AS users
  FROM affected a JOIN sub_counts sc ON sc.id = a.id
 WHERE a.is_suffixed AND a.username <> '' AND sc.subs = 0
UNION ALL
SELECT 'suffixed rows with subscriptions (need merge or rename)', count(*)
  FROM affected a JOIN sub_counts sc ON sc.id = a.id
 WHERE a.is_suffixed AND a.username <> '' AND sc.subs > 0;

\echo ''
\echo '=== 4. Dangerous pairs: both sides hold an active subscription ==='
\echo '    Quota checks and usage recording can land on different rows for one person.'
SELECT suffixed, bare, sfx_subs, sfx_active, bare_subs, bare_active
  FROM pairs WHERE sfx_active > 0 AND bare_active > 0
 ORDER BY suffixed LIMIT 100;

\echo ''
\echo '=== 5. The blank-username row and any whitespace-padded rows ==='
SELECT a.username, sc.subs, sc.active_subs
  FROM affected a JOIN sub_counts sc ON sc.id = a.id WHERE a.username = '';
SELECT id, '['||username||']' AS padded_username FROM users WHERE username <> btrim(username);

\echo ''
\echo '=== 6. Which side of each pair is live -- this drives the merge ==='
SELECT CASE
         WHEN sfx_active > 0 AND bare_active > 0 THEN 'both sides active (needs a human)'
         WHEN sfx_active > 0                     THEN 'only the suffixed row is active'
         WHEN bare_active > 0                    THEN 'only the bare row is active'
         ELSE                                         'neither side active'
       END AS shape,
       count(*) AS pairs,
       sum(sfx_subs) AS subs_on_suffixed,
       sum(bare_subs) AS subs_on_bare
  FROM pairs
 GROUP BY 1 ORDER BY pairs DESC;

\echo ''
\echo '=== 7. Indexes on the big tables (do the merge UPDATEs have support?) ==='
SELECT tablename, indexname, indexdef
  FROM pg_indexes
 WHERE schemaname='public' AND tablename IN ('updates','usages','quotas','subscriptions')
 ORDER BY tablename, indexname;

-- NOT RUN BY DEFAULT. The updates table is ~340M rows / 59 GB in production and
-- updates.user_id may be unindexed, so a per-user count is a full scan each.
-- Counting audit rows is not needed to decide a merge; run this deliberately,
-- once, if you want the totals:
--
--   SELECT up.user_id, count(*)
--     FROM updates up JOIN decide d ON d.id = up.user_id
--    GROUP BY up.user_id;
