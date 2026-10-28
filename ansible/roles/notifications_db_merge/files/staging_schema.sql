-- Staging copy of the standalone notifications database, created inside the DE
-- database so the load can join against public.users. Deliberately hand-written
-- rather than restored from the pg_dump: the dump fully qualifies every object
-- as "public", and rewriting that to another schema means editing a file that
-- also contains the jsonb payloads. The rows arrive by \copy instead.
--
-- schema_migrations is not staged; the standalone database's migration history
-- does not carry over.
--
-- Expects -v staging=<schema name>. The caller is responsible for refusing to
-- pass "public" here, since this drops the schema it is given.

BEGIN;

DROP SCHEMA IF EXISTS :"staging" CASCADE;
CREATE SCHEMA :"staging";

SET search_path = :"staging";

CREATE TABLE users (
    id uuid NOT NULL PRIMARY KEY,
    username varchar(512) NOT NULL UNIQUE
);

CREATE TABLE notification_types (
    id uuid NOT NULL PRIMARY KEY,
    name varchar(32) NOT NULL UNIQUE
);

CREATE TABLE notifications (
    id uuid NOT NULL PRIMARY KEY,
    notification_type_id uuid NOT NULL,
    user_id uuid NOT NULL,
    subject text NOT NULL,
    seen boolean NOT NULL,
    deleted boolean NOT NULL,
    time_created timestamp with time zone NOT NULL,
    incoming_json jsonb NOT NULL,
    outgoing_json jsonb,
    routing_key varchar(64)
);

-- Supports the user_id join in transform.sql; the table arrives with 800k+ rows.
CREATE INDEX notifications_staging_user_id_index ON notifications (user_id);

COMMIT;
