-- Moves the staged notification rows into public.notifications, resolving the
-- two identifiers that differ between the databases:
--
--   users  the standalone database stores bare usernames ("jdoe"); public.users
--          stores them qualified ("jdoe@iplantcollaborative.org"). No user has
--          the same id in both databases, so every user_id is remapped.
--   types  the standalone database keys notifications to its own
--          notification_types rows; migration 000055 seeded public by name.
--
-- Expects -v staging=<schema name> -v uid_domain=<domain> -v junk_pattern=<like pattern>.
-- Idempotent: re-running loads only notifications not already present.

BEGIN;

SET search_path = public, pg_catalog;

--
-- Create DE users for staged accounts that have never been seen by the rest of
-- the DE. These are real people who received a notification without ever
-- launching an analysis. Junk subject IDs are excluded here and their
-- notifications are dropped below.
--
INSERT INTO users (username)
SELECT su.username || '@' || :'uid_domain'
FROM :"staging".users su
WHERE su.username NOT LIKE :'junk_pattern'
ON CONFLICT (username) DO NOTHING;

--
-- Resolve every staged user to a DE user.
--
-- The single-@ preference matters: 128k of public.users' rows are
-- "name@@domain" duplicates of a "name@domain" row, and it is the single-@ row
-- that the rest of the DE references. DISTINCT ON with this ordering picks it
-- deterministically even where both spellings exist.
--
CREATE TEMPORARY TABLE user_map ON COMMIT DROP AS
SELECT DISTINCT ON (su.id)
       su.id AS staged_id,
       u.id  AS de_id
FROM :"staging".users su
JOIN users u ON u.username IN (
        su.username || '@' || :'uid_domain',
        su.username || '@@' || :'uid_domain'
     )
WHERE su.username NOT LIKE :'junk_pattern'
ORDER BY su.id, (u.username LIKE '%@@%');

CREATE UNIQUE INDEX ON user_map (staged_id);

--
-- Resolve staged notification types by name. Migration 000055 seeded all nine
-- names, so an unmatched row means the standalone database grew a tenth after
-- that migration was written; the count check below will catch it.
--
CREATE TEMPORARY TABLE type_map ON COMMIT DROP AS
SELECT st.id AS staged_id,
       nt.id AS de_id
FROM :"staging".notification_types st
JOIN notification_types nt ON nt.name = st.name;

CREATE UNIQUE INDEX ON type_map (staged_id);

--
-- Notification ids are preserved. They are distinct from every id already in
-- the DE database, and clients hold them: outgoing_json embeds the id as
-- message.id and the update endpoints address notifications by it.
--
INSERT INTO notifications (
    id, notification_type_id, user_id, subject, seen, deleted,
    time_created, incoming_json, outgoing_json, routing_key
)
SELECT sn.id, tm.de_id, um.de_id, sn.subject, sn.seen, sn.deleted,
       sn.time_created, sn.incoming_json, sn.outgoing_json, sn.routing_key
FROM :"staging".notifications sn
JOIN user_map um ON um.staged_id = sn.user_id
JOIN type_map tm ON tm.staged_id = sn.notification_type_id
ON CONFLICT (id) DO NOTHING;

COMMIT;
