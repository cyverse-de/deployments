-- Reconciles the load against the staged rows. Returns one row; the playbook
-- asserts on it rather than raising here, so a failure prints every count
-- instead of only the first one that tripped.
--
-- Expects -v staging=<schema name> -v uid_domain=<domain> -v junk_pattern=<like pattern>.

SET search_path = public, pg_catalog;

WITH resolved AS (
    SELECT su.id
    FROM :"staging".users su
    WHERE su.username NOT LIKE :'junk_pattern'
      AND EXISTS (
          SELECT 1 FROM users u
          WHERE u.username IN (
              su.username || '@' || :'uid_domain',
              su.username || '@@' || :'uid_domain'
          )
      )
)
SELECT
    (SELECT count(*) FROM :"staging".notifications) AS staged_notifications,
    (SELECT count(*) FROM :"staging".users)         AS staged_users,

    -- Deliberately discarded: iplant-groups subject IDs, not people.
    (SELECT count(*) FROM :"staging".users
      WHERE username LIKE :'junk_pattern')          AS junk_users,
    (SELECT count(*) FROM :"staging".notifications sn
      JOIN :"staging".users su ON su.id = sn.user_id
     WHERE su.username LIKE :'junk_pattern')        AS junk_notifications,

    -- Should be zero: transform.sql creates a DE user for every non-junk
    -- staged account before mapping.
    (SELECT count(*) FROM :"staging".users su
      WHERE su.username NOT LIKE :'junk_pattern'
        AND su.id NOT IN (SELECT id FROM resolved)) AS unmapped_users,
    (SELECT count(*) FROM :"staging".notification_types st
      WHERE NOT EXISTS (SELECT 1 FROM notification_types nt
                         WHERE nt.name = st.name))  AS unmapped_types,

    -- What should have landed, and what did.
    (SELECT count(*) FROM :"staging".notifications sn
      WHERE sn.user_id IN (SELECT id FROM resolved)) AS expected_notifications,
    (SELECT count(*) FROM notifications)             AS loaded_notifications;
