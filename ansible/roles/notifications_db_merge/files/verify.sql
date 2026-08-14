-- Reconciles the load against the staged rows. Returns one row; the playbook
-- asserts on it rather than raising here, so a failure prints every count
-- instead of only the first one that tripped.
--
-- Expects -v staging=<schema name> -v uid_domain=<domain> -v junk_pattern=<like pattern>.

SET search_path = public, pg_catalog;

WITH staged_user AS (
    -- Same qualification rule as transform.sql: truncate at the first '@'
    -- before appending, matching apps.user/append-username-suffix.
    SELECT su.id,
           regexp_replace(su.username, '@.*$', '') || '@'  || :'uid_domain' AS de_username,
           regexp_replace(su.username, '@.*$', '') || '@@' || :'uid_domain' AS de_username_malformed
    FROM :"staging".users su
    WHERE su.username NOT LIKE :'junk_pattern'
),
resolved AS (
    SELECT sc.id
    FROM staged_user sc
    WHERE EXISTS (
        SELECT 1 FROM users u
        WHERE u.username IN (sc.de_username, sc.de_username_malformed)
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
    (SELECT count(*) FROM staged_user sc
      WHERE sc.id NOT IN (SELECT id FROM resolved)) AS unmapped_users,
    (SELECT count(*) FROM :"staging".notification_types st
      WHERE NOT EXISTS (SELECT 1 FROM notification_types nt
                         WHERE nt.name = st.name))  AS unmapped_types,

    -- Two staged accounts qualifying to one DE username -- "jdoe" and
    -- "jdoe@elsewhere.edu" both resolve to "jdoe@<uid_domain>". Neither
    -- environment has any today. If one appears, their notification histories
    -- would silently merge under a single DE user, so this fails the load
    -- rather than guessing that they are the same person.
    (SELECT count(*) FROM (
        SELECT de_username FROM staged_user
        GROUP BY de_username HAVING count(*) > 1
     ) c)                                           AS colliding_users,

    -- What should have landed, and what did.
    (SELECT count(*) FROM :"staging".notifications sn
      WHERE sn.user_id IN (SELECT id FROM resolved)) AS expected_notifications,
    (SELECT count(*) FROM notifications)             AS loaded_notifications;
