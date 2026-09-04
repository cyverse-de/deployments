-- Builds a synthetic dataset in the permissions schema at production's size and
-- shape, so the group-expansion hot path can be measured without copying real
-- user data onto a development machine.
--
--   psql -h localhost -p 15432 -U de -d de \
--        -v confirm=yes -f synthesize-perf-dataset.sql
--
--   -v scale=0.1   a tenth of production, for a quick check (default 1.0)
--
-- Everything it writes is marked: user subjects are named perfuser*, groups and
-- resources perf-*. Cleanup and re-runs match on those markers, so the script
-- cannot delete rows it did not create. It is idempotent -- a second run
-- replaces the dataset rather than adding to it.
--
-- NEVER run this against QA or production. It writes ~1.5M rows and deletes any
-- pre-existing perf-* rows.

-- Two steps because :{?confirm} only asks whether the variable is defined:
-- -v confirm=no would otherwise sail straight through.
\if :{?confirm}
\else
\set confirm no
\endif

\if :confirm
\else
\echo '!! refusing to run: pass -v confirm=yes'
\echo '!! this writes ~1.5M rows and is only ever meant for a scratch database'
\quit
\endif

\if :{?scale}
\else
\set scale 1.0
\endif

-- Stop at the first error. Without this psql runs on, and a dataset that is
-- missing whichever step failed still prints a plausible-looking summary --
-- which is indistinguishable from a good run until a benchmark reads it.
\set ON_ERROR_STOP on

\timing on
SET search_path TO permissions, public;

\echo ''
\echo '== target sizes (scale' :scale ')'

-- Production figures measured against grainger during Phase 0b/4, scaled. They
-- are kept in one place because the point of this dataset is the ratios between
-- them, not any single count.
CREATE TEMP TABLE perf_cfg AS
SELECT greatest(1, round(44700 * :scale))::int   AS n_users,
       greatest(4, round(2583  * :scale))::int   AS n_groups,
       greatest(1, round(44600 * :scale))::int   AS n_de_users_members,
       greatest(1, round(9400  * :scale))::int   AS n_other_members,
       greatest(2, round(152   * :scale))::int   AS n_nested,
       greatest(10, round(1490909 * :scale))::int AS n_resources,
       -- de-users reaches every user, so what it holds is added to every
       -- expansion in the deployment. It is the reason the cap exists.
       greatest(1, round(1000 * :scale))::int    AS n_de_users_grants,
       -- Production's largest group-held grant count, measured at 3,323.
       greatest(1, round(3323 * :scale))::int    AS n_big_group_grants;

SELECT * FROM perf_cfg;

\echo ''
\echo '== index on permissions.resource_id'

-- The schema indexes (subject_id, resource_id) but nothing on resource_id
-- alone, so the FK check behind ON DELETE CASCADE from resources scans the
-- whole permissions table once per deleted resource. Clearing this dataset
-- without it does not finish in ten minutes; with it, under four seconds.
-- It does not affect the group-expansion measurements, which filter on
-- subject_id -- but the DE schema should carry it, and does not.
CREATE INDEX IF NOT EXISTS permissions_resource_id_idx
    ON permissions.permissions (resource_id);

\echo ''
\echo '== clearing any previous synthetic rows'

-- Membership goes first, and deliberately. Deleting a group fires the BEFORE
-- DELETE trigger, which recomputes the closure of every group containing it --
-- and when a whole set of nested groups is dropped in one statement, a
-- container can already be gone by the time its child is deleted, leaving the
-- trigger inserting closure rows for a group that no longer exists. Clearing
-- membership first leaves it nothing to recompute.
DELETE FROM group_memberships
 WHERE group_id IN (SELECT subject_id FROM groups WHERE name LIKE 'perf-%')
    OR member_id IN (SELECT subject_id FROM groups WHERE name LIKE 'perf-%');

-- Group resources are named by the group's external id, not by anything
-- matching 'perf-%', so they have to be found through the group they belong to
-- and dropped before the group itself goes.
DELETE FROM resources r
 USING groups g
  JOIN subjects gs ON gs.id = g.subject_id
 WHERE g.name LIKE 'perf-%' AND r.name = gs.subject_id;

-- Deleting a subject cascades its groups row, closure, and any permissions
-- held by it; deleting a resource cascades permissions on it.
DELETE FROM subjects
 WHERE id IN (SELECT subject_id FROM groups WHERE name LIKE 'perf-%');
DELETE FROM subjects WHERE subject_id LIKE 'perfuser%' OR subject_id = 'perfbench';
DELETE FROM resources WHERE name LIKE 'perf-%';
DELETE FROM users WHERE username LIKE 'perfuser%@%' OR username LIKE 'perfbench@%';

\echo ''
\echo '== users'

-- A DE user row per subject, so subjects.user_id correlates the way the
-- importer and both services expect.
INSERT INTO users (id, username)
SELECT uuid_generate_v1(), 'perfuser' || lpad(g::text, 6, '0') || '@iplantcollaborative.org'
  FROM perf_cfg, generate_series(1, perf_cfg.n_users) g;
INSERT INTO users (id, username) VALUES (uuid_generate_v1(), 'perfbench@iplantcollaborative.org');

INSERT INTO subjects (subject_id, subject_type, user_id)
SELECT 'perfuser' || lpad(g::text, 6, '0'), 'user',
       (SELECT id FROM users u
         WHERE u.username = 'perfuser' || lpad(g::text, 6, '0') || '@iplantcollaborative.org')
  FROM perf_cfg, generate_series(1, perf_cfg.n_users) g;

-- The subject every measurement is taken as. Named rather than picked at
-- random so a benchmark run is comparable across regenerations.
INSERT INTO subjects (subject_id, subject_type, user_id)
SELECT 'perfbench', 'user',
       (SELECT id FROM users WHERE username = 'perfbench@iplantcollaborative.org');

CREATE TEMP TABLE perf_users AS
SELECT row_number() OVER (ORDER BY subject_id) AS n, id
  FROM subjects WHERE subject_id LIKE 'perfuser%';
CREATE INDEX ON perf_users (n);
ANALYZE perf_users;

\echo ''
\echo '== groups'

-- The type mix measured in production: 52 communities, the rest split between
-- teams and collaborator lists, plus de-users.
CREATE TEMP TABLE perf_groups AS
SELECT g AS n,
       uuid_generate_v1() AS sid,
       CASE
           WHEN g = 1 THEN 'system'
           WHEN g <= 53 THEN 'community'
           WHEN g <= round(53 + (perf_cfg.n_groups - 53) * 0.2) THEN 'team'
           ELSE 'collaborator_list'
       END AS group_type
  FROM perf_cfg, generate_series(1, perf_cfg.n_groups) g;

ALTER TABLE perf_groups ADD COLUMN owner varchar(512);
UPDATE perf_groups
   SET owner = CASE WHEN group_type IN ('team', 'collaborator_list')
                    THEN 'perfuser' || lpad((((n * 7919) % (SELECT n_users FROM perf_cfg)) + 1)::text, 6, '0')
               END;
CREATE INDEX ON perf_groups (n);
CREATE INDEX ON perf_groups (sid);

-- Group IDs are 32 hex digits with no dashes, the shape Grouper used and the
-- shape subjects.subject_id defaults to. iRODS names groups from these.
INSERT INTO subjects (id, subject_id, subject_type)
SELECT sid, replace(uuid_generate_v1()::text, '-', ''), 'group' FROM perf_groups;

-- owner_present is generated from owner, so it is never written directly.
INSERT INTO groups (subject_id, group_type, owner, name, display_name, description)
SELECT sid,
       group_type,
       owner,
       CASE WHEN n = 1 THEN 'perf-de-users' ELSE 'perf-group-' || n END,
       CASE WHEN n = 1 THEN 'perf-de-users' ELSE 'perf-group-' || n END,
       'synthetic'
  FROM perf_groups;

\echo ''
\echo '== direct membership'

-- de-users holds essentially every DE user. This single group is what makes an
-- expansion expensive, and a dataset without it understates the hot path badly
-- no matter how many rows the other tables have.
INSERT INTO group_memberships (group_id, member_id, member_type)
SELECT (SELECT sid FROM perf_groups WHERE n = 1), u.id, 'user'
  FROM perf_cfg, perf_users u
 WHERE u.n <= perf_cfg.n_de_users_members
ON CONFLICT DO NOTHING;

-- Everything else is small: the remaining memberships spread over every other
-- group, which in production averages out to a handful each.
-- Scalar subqueries rather than a join to perf_cfg: a comma-joined table is not
-- in scope inside an ON clause further down the join tree.
INSERT INTO group_memberships (group_id, member_id, member_type)
SELECT pg.sid, pu.id, 'user'
  FROM perf_groups pg
       CROSS JOIN LATERAL
         generate_series(1, greatest(1, (SELECT n_other_members / n_groups + 1 FROM perf_cfg))) j
       JOIN perf_users pu
         ON pu.n = (((pg.n * 104729 + j * 7919) % (SELECT n_users FROM perf_cfg)) + 1)
 WHERE pg.n > 1
ON CONFLICT DO NOTHING;

-- The benchmark subject: in de-users like everyone, in the group holding the
-- largest grant count, and in a handful of ordinary ones. Nine total, matching
-- the user the production measurement was taken as.
INSERT INTO group_memberships (group_id, member_id, member_type)
SELECT pg.sid, (SELECT id FROM subjects WHERE subject_id = 'perfbench'), 'user'
  FROM perf_groups pg
 WHERE pg.n IN (1, 2, 3, 4, 5, 6, 7, 8, 9)
ON CONFLICT DO NOTHING;

\echo ''
\echo '== nested groups'

-- Nesting is in regular use in production and occasionally exceeds one level.
-- The pairs step by three so they stay disjoint: chaining consecutive groups
-- instead makes every group absorb the whole tail below it, which inflates the
-- closure far past production's and makes the hot path look worse than it is.
INSERT INTO group_memberships (group_id, member_id, member_type)
SELECT parent.sid, child.sid, 'group'
  FROM generate_series(1, (SELECT least(n_nested, (n_groups - 12) / 3) FROM perf_cfg)) i
       JOIN perf_groups parent ON parent.n = 10 + (i - 1) * 3
       JOIN perf_groups child  ON child.n  = 11 + (i - 1) * 3
ON CONFLICT DO NOTHING;

-- A handful go one level deeper, so the closure is genuinely transitive rather
-- than a single hop everywhere.
INSERT INTO group_memberships (group_id, member_id, member_type)
SELECT child.sid, grandchild.sid, 'group'
  FROM generate_series(1, (SELECT least(10, least(n_nested, (n_groups - 12) / 3)) FROM perf_cfg)) i
       JOIN perf_groups child      ON child.n      = 11 + (i - 1) * 3
       JOIN perf_groups grandchild ON grandchild.n = 12 + (i - 1) * 3
ON CONFLICT DO NOTHING;

\echo ''
\echo '== effective membership (via the schema''s own recompute_group_closure)'

-- Built by the function the service calls on every membership write, so the
-- closure is produced by the real code path and its cost is measured here too.
SELECT recompute_group_closure(array_agg(sid)) FROM perf_groups;

\echo ''
\echo '== resources'

INSERT INTO resources (name, resource_type_id)
SELECT 'perf-' || g,
       (SELECT id FROM resource_types
         WHERE name = CASE WHEN g % 100 = 0 THEN 'tool'
                           WHEN g % 3 = 0 THEN 'app'
                           ELSE 'analysis' END)
  FROM perf_cfg, generate_series(1, perf_cfg.n_resources) g;

CREATE TEMP TABLE perf_resources AS
SELECT row_number() OVER (ORDER BY id) AS n, id FROM resources WHERE name LIKE 'perf-%';
CREATE INDEX ON perf_resources (n);
ANALYZE perf_resources;

\echo ''
\echo '== permissions'

-- One owner per resource, skewed: cubing a uniform draw concentrates ownership
-- on a minority of users, which is how real DE ownership is distributed. A flat
-- distribution would give the planner uniform statistics it does not have in
-- production.
-- The owner index is drawn once per resource in a subquery fenced with OFFSET
-- 0. Putting random() in the join condition instead re-evaluates it for every
-- candidate row, so a resource matches zero or several users and the row count
-- overshoots -- which silently destroys the ownership distribution this is here
-- to reproduce.
SELECT setseed(0.42);
INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT pu.id, t.rid, (SELECT id FROM permission_levels WHERE name = 'own')
  FROM (SELECT pr.id AS rid,
               1 + floor((SELECT n_users FROM perf_cfg) * power(random(), 3))::int AS un
          FROM perf_resources pr
        OFFSET 0) t
       JOIN perf_users pu ON pu.n = t.un
ON CONFLICT DO NOTHING;

-- What de-users holds is reached by every user in the deployment.
INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT (SELECT sid FROM perf_groups WHERE n = 1), pr.id,
       (SELECT id FROM permission_levels WHERE name = 'read')
  FROM perf_cfg, perf_resources pr
 WHERE pr.n <= perf_cfg.n_de_users_grants
ON CONFLICT DO NOTHING;

-- One group carrying an outsized number of grants, as production has. Offset
-- past the de-users block so the two do not overlap, and kept inside the table
-- at any scale.
INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT (SELECT sid FROM perf_groups WHERE n = 2), pr.id,
       (SELECT id FROM permission_levels WHERE name = 'read')
  FROM perf_cfg, perf_resources pr
 WHERE pr.n > perf_cfg.n_de_users_grants
   AND pr.n <= perf_cfg.n_de_users_grants + perf_cfg.n_big_group_grants
ON CONFLICT DO NOTHING;

-- Ordinary group-held grants across the rest.
INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT pg.sid, pr.id, (SELECT id FROM permission_levels WHERE name = 'read')
  FROM perf_groups pg
       CROSS JOIN LATERAL generate_series(1, 3) j
       JOIN perf_resources pr
         ON pr.n = ((pg.n * 31 + j * 977) % (SELECT n_resources FROM perf_cfg)) + 1
 WHERE pg.n > 2
ON CONFLICT DO NOTHING;

-- Every group is also a resource, and the resource's name is the group's
-- EXTERNAL id -- the 32-hex subject_id, not anything derived from its name.
-- That is what the groups service passes to the permissions service when it
-- authorizes a request, so a resource named any other way authorizes nothing:
-- the group's own owner gets a 403 on it.
INSERT INTO resources (name, resource_type_id)
SELECT gs.subject_id, (SELECT id FROM resource_types WHERE name = 'group')
  FROM perf_groups pg
       JOIN subjects gs ON gs.id = pg.sid
ON CONFLICT DO NOTHING;

-- The owner holds `own`, joined on the groups.owner value itself rather than
-- recomputing the index, so the grant cannot drift from the column.
INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT owner_s.id, r.id, (SELECT id FROM permission_levels WHERE name = 'own')
  FROM perf_groups pg
       JOIN subjects gs ON gs.id = pg.sid
       JOIN resources r ON r.name = gs.subject_id
       JOIN subjects owner_s ON owner_s.subject_id = pg.owner
                            AND owner_s.subject_type = 'user'
 WHERE pg.owner IS NOT NULL
ON CONFLICT DO NOTHING;

-- Public teams and communities are marked by a read grant to GrouperAll, a
-- group-typed subject with no group row and no members. Production carries 183
-- public teams and 55 public communities; without them every group is private
-- and the browse-then-open flow cannot be exercised at all.
INSERT INTO subjects (subject_id, subject_type)
SELECT 'GrouperAll', 'group'
 WHERE NOT EXISTS (SELECT 1 FROM subjects WHERE subject_id = 'GrouperAll');

INSERT INTO permissions (subject_id, resource_id, permission_level_id)
SELECT (SELECT id FROM subjects WHERE subject_id = 'GrouperAll'),
       r.id,
       (SELECT id FROM permission_levels WHERE name = 'read')
  FROM perf_groups pg
       JOIN subjects gs ON gs.id = pg.sid
       JOIN resources r ON r.name = gs.subject_id
 WHERE (pg.group_type = 'team'      AND pg.n % 3 = 0)
    OR (pg.group_type = 'community' AND pg.n % 1 = 0)
ON CONFLICT DO NOTHING;

\echo ''
\echo '== analyzing'

ANALYZE permissions;
ANALYZE resources;
ANALYZE subjects;
ANALYZE groups;
ANALYZE group_memberships;
ANALYZE group_effective_members;

\echo ''
\echo '== result'

SELECT 'permissions'             AS table, count(*) FROM permissions
UNION ALL SELECT 'resources',              count(*) FROM resources
UNION ALL SELECT 'subjects',               count(*) FROM subjects
UNION ALL SELECT 'groups',                 count(*) FROM groups
UNION ALL SELECT 'group_memberships',      count(*) FROM group_memberships
UNION ALL SELECT 'nested memberships',     count(*) FROM group_memberships WHERE member_type = 'group'
UNION ALL SELECT 'group_effective_members', count(*) FROM group_effective_members
UNION ALL SELECT 'public.users',           count(*) FROM users;

\echo ''
\echo '== the benchmark subject'

SELECT (SELECT count(*) FROM group_effective_members em
         JOIN subjects s ON s.id = em.member_id
        WHERE s.subject_id = 'perfbench')                   AS groups_reached,
       (SELECT count(*) FROM permissions p
         WHERE p.subject_id IN (
             SELECT id FROM subjects WHERE subject_id = 'perfbench'
             UNION
             SELECT em.group_id FROM group_effective_members em
               JOIN subjects s ON s.id = em.member_id
              WHERE s.subject_id = 'perfbench'))            AS permissions_reached;

\timing off
