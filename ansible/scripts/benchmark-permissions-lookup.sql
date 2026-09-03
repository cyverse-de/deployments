-- Compares the permission-lookup shapes against the synthetic dataset built by
-- synthesize-perf-dataset.sql: the inlined group expansion the permissions
-- service ships today, and the literal-array form it replaced, which fed an
-- ID list back in from a separate service call.
--
--   psql -h localhost -p 15432 -U de -d de -f benchmark-permissions-lookup.sql
--
--   -v subject=perfbench   whose permissions to look up (default perfbench)
--
-- Read the plan shapes, not just the times. The two forms differ in whether the
-- planner can use permissions(subject_id, resource_id) directly, and that is
-- what decides the cost -- a warm cache flatters both equally.

\set ON_ERROR_STOP on

\if :{?subject}
\else
\set subject perfbench
\endif

SET search_path TO permissions, public;

\echo ''
\echo '== dataset'

SELECT (SELECT count(*) FROM permissions)             AS permissions,
       (SELECT count(*) FROM resources)               AS resources,
       (SELECT count(*) FROM group_effective_members) AS closure,
       (SELECT count(*) FROM groups)                  AS groups;

\echo ''
\echo '== subject under test'

SELECT :'subject' AS subject,
       (SELECT count(*) FROM group_effective_members em
          JOIN subjects s ON s.id = em.member_id
         WHERE s.subject_id = :'subject')  AS groups_reached,
       (SELECT count(*) FROM permissions p
         WHERE p.subject_id IN (
             SELECT id FROM subjects WHERE subject_id = :'subject'
             UNION
             SELECT em.group_id FROM group_effective_members em
               JOIN subjects s ON s.id = em.member_id
              WHERE s.subject_id = :'subject')) AS permissions_reached;

-- The literal array the old form was given: the subject plus every group it
-- belongs to, which used to arrive over HTTP from a separate service. It is
-- interpolated as real literals rather than passed as a subquery, because the
-- shape being compared is precisely one where the planner sees a constant list
-- of known length.
SELECT '''' || array_to_string(array_agg(subject_id), ''',''') || '''' AS idlist,
       count(*) > 0 AS have_subject
  FROM (SELECT s2.subject_id
          FROM subjects s2 WHERE s2.subject_id = :'subject'
         UNION
        SELECT gs.subject_id
          FROM group_effective_members em
          JOIN subjects s ON s.id = em.member_id
          JOIN subjects gs ON gs.id = em.group_id
         WHERE s.subject_id = :'subject') t
\gset

-- array_agg over no rows is NULL, which \gset turns into an empty idlist and
-- query B into ANY(ARRAY[]) -- a "cannot determine type of empty array" error
-- rather than a word about the subject that does not exist.
\if :have_subject
\else
\echo '!! no such subject:' :subject
\quit
\endif

\echo ''
\echo '###############################################################'
\echo '## A. lookup=true, inlined expansion   (what ships today)'
\echo '###############################################################'

EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING)
WITH requester AS (
    SELECT id FROM subjects WHERE subject_id = :'subject'
),
subject_ids AS (
    SELECT id FROM requester
    UNION
    SELECT em.group_id
      FROM group_effective_members em
      JOIN requester r ON em.member_id = r.id
)
SELECT p.id, s.subject_id, s.subject_type, r.name, rt.name, pl.name
  FROM permissions p
  JOIN subjects s ON s.id = p.subject_id
  JOIN resources r ON r.id = p.resource_id
  JOIN resource_types rt ON rt.id = r.resource_type_id
  JOIN permission_levels pl ON pl.id = p.permission_level_id
 WHERE p.subject_id IN (SELECT id FROM subject_ids);

\echo ''
\echo '###############################################################'
\echo '## B. lookup=true, literal array       (the Grouper-backed form)'
\echo '###############################################################'

EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING)
SELECT p.id, s.subject_id, s.subject_type, r.name, rt.name, pl.name
  FROM permissions p
  JOIN subjects s ON s.id = p.subject_id
  JOIN resources r ON r.id = p.resource_id
  JOIN resource_types rt ON rt.id = r.resource_type_id
  JOIN permission_levels pl ON pl.id = p.permission_level_id
 WHERE s.subject_id = ANY(ARRAY[:idlist]);

\echo ''
\echo '###############################################################'
\echo '## C. lookup=false, no expansion       (the cheap path)'
\echo '###############################################################'

EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING)
SELECT p.id, s.subject_id, s.subject_type, r.name, rt.name, pl.name
  FROM permissions p
  JOIN subjects s ON s.id = p.subject_id
  JOIN resources r ON r.id = p.resource_id
  JOIN resource_types rt ON rt.id = r.resource_type_id
  JOIN permission_levels pl ON pl.id = p.permission_level_id
 WHERE s.subject_id = :'subject';

\echo ''
\echo '###############################################################'
\echo '## E. expand_groups=true on a resource de-users holds'
\echo '###############################################################'

-- The worst case in the deployment, and the one the plan called out as being
-- "slow enough over HTTP today that nobody runs it": a resource granted to
-- de-users expands to every member of de-users. This is the query that replaced
-- an N+1 loop, and the reason max_expanded_subjects exists.
SELECT r.name AS pubres, rt.name AS pubtype
  FROM permissions p
  JOIN resources r ON r.id = p.resource_id
  JOIN resource_types rt ON rt.id = r.resource_type_id
 WHERE p.subject_id = (SELECT subject_id FROM groups WHERE name = 'perf-de-users')
 LIMIT 1
\gset

\echo 'resource under test:' :pubres '(' :pubtype ')'

EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING)
WITH matching AS (
    SELECT p.id, p.subject_id, p.permission_level_id,
           r.id AS resource_id, r.name AS resource_name, rt.name AS resource_type
      FROM permissions p
      JOIN resources r ON r.id = p.resource_id
      JOIN resource_types rt ON rt.id = r.resource_type_id
     WHERE rt.name = :'pubtype' AND r.name = :'pubres'
),
expanded AS (
    SELECT m.id, s.id AS internal_subject_id, s.subject_id, s.subject_type,
           m.permission_level_id, m.resource_id, m.resource_name, m.resource_type
      FROM matching m
      JOIN subjects s ON s.id = m.subject_id
     WHERE s.subject_type = 'user'
    UNION ALL
    SELECT m.id, ms.id, ms.subject_id, ms.subject_type,
           m.permission_level_id, m.resource_id, m.resource_name, m.resource_type
      FROM matching m
      JOIN subjects gs ON gs.id = m.subject_id AND gs.subject_type = 'group'
      JOIN group_effective_members em ON em.group_id = gs.id
      JOIN subjects ms ON ms.id = em.member_id
)
SELECT DISTINCT ON (e.internal_subject_id)
       e.id, e.internal_subject_id, e.subject_id, e.subject_type,
       e.resource_id, e.resource_name, e.resource_type, pl.name
  FROM expanded e
  JOIN permission_levels pl ON pl.id = e.permission_level_id
 ORDER BY e.internal_subject_id, pl.precedence
 LIMIT 10001;

\echo ''
\echo '###############################################################'
\echo '## D. closure recomputation for one group'
\echo '###############################################################'

-- What every membership write pays. de-users is the worst case in the
-- deployment because it reaches every user.
\timing on
SELECT recompute_group_closure(ARRAY[(SELECT subject_id FROM groups WHERE name = 'perf-de-users')]);
\timing off
