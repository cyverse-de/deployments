# PostgreSQL deployment

PostgreSQL is installed and initialized as part of the `kubernetes.yml`
playbook. Two tagged passes handle it:

* `install-postgres` — installs and configures the PostgreSQL server.
* `setup-databases` — creates the roles and databases the DE services need, and
  runs their schema migrations.

The `databases` tag runs both passes.

PostgreSQL 14 is the minimum supported version. The playbooks write `pg_hba.conf`
rules that use `scram-sha-256` authentication, which relies on the SCRAM password
hashing that PostgreSQL 14 and newer use by default.

## Passes

### install-postgres

Runs against the `dbms` host group with `become: true`, via two roles:

* `postgresql` — installs the PostgreSQL server and client packages and opens TCP
  port 5432 on the active firewall (firewalld or ufw).
* `postgresql_access` — adds the `host` rules to `pg_hba.conf`, sets
  `listen_addresses` to `*`, and sets the `postgres` superuser password.

This pass is **optional**: skip it when the deployment uses a PostgreSQL instance
that was provisioned in advance, and run `setup-databases` directly against that
instance instead.

```bash
ansible-playbook -i /path/to/inventory --tags=install-postgres kubernetes.yml
```

### setup-databases

Runs locally (`connection: local`) and connects to the first host in the `dbms`
inventory group. It runs the `postgresql_init` role, which:

* creates the DE service roles and databases,
* installs the PostgreSQL extensions those databases require (`uuid-ossp`,
  `moddatetime`, `btree_gist`, ...), and
* checks out the migration repositories and applies them with the `migrate` tool.

The Discovery Environment databases (`de`, `notifications`, `metadata`) are always
created. The Grouper, QMS, Harbor, Keycloak, and User Portal databases
are each created only when their feature toggle is enabled.

This pass needs the `migrate` command (golang-migrate) on the control host's
`PATH`. See [index.md](index.md) for tool requirements.

```bash
ansible-playbook -i /path/to/inventory --tags=setup-databases kubernetes.yml
```

## Inventory Setup

```
[dbms]
db.example.org

[keycloak_dbms]
db.example.org
```

The `dbms` group holds the PostgreSQL host for the Discovery Environment
databases. The `keycloak_dbms` group holds the host for the Keycloak database —
it may be the same server or a separate one. Both passes use the first host
listed in each group.

## Group Variable Setup

Every variable consulted by these passes has a default in
`roles/common/defaults/main.yml`. The example inventory ships an annotated,
copy-and-edit reference of them — grouped by pass — at
`example/inventory/group_vars/all.yaml`. Copy that file into the private
inventory repository and uncomment the values you need to override.

The most commonly overridden variables are:

Variable                          | Default      | Comments
--------------------------------- | ------------ | --------
`dbms_postgresql_version`          | `14`         | major version of the PostgreSQL packages to install; 14 is the minimum supported version
`pg_login_password`               | `Chang3m3`   | password assigned to the `postgres` superuser
`dbms_connection_user`            | `de`         | role that owns the Discovery Environment databases
`dbms_connection_pass`            | `Ch@ng3M3`   | password for `dbms_connection_user`
`dbms_allowed_remote_addresses`   | `[]`         | additional CIDR ranges granted access in `pg_hba.conf`

See the example file for the rest, including the per-feature database names,
owners, and migration repository refs.

## Related playbooks

`big_dumper.yml` (the `db_copy_prod` role) is a separate utility for copying
production database contents; it is not part of the standard deployment flow
described above.

---

## Day-to-day database operations

The sections below cover operational tasks that come up after the initial deployment.

```bash
export DBMS_HOST=<dbms-host>   # from dbms_host in the inventory
export DBMS_PASS=<password>    # from dbms_connection_pass in the inventory
```

### Connecting to the database from a workstation

PostgreSQL runs on the `dbms` inventory host, not as a Kubernetes service. It is typically
accessible directly from operator workstations (or via VPN, depending on the deployment).

```bash
# Connect directly to the dbms host (get the hostname from the inventory)
psql -h $DBMS_HOST -U de -d de
# password is dbms_connection_pass from the inventory (set as $DBMS_PASS above)
```

The databases are:

| Database | Purpose |
|---|---|
| `de` | Main DE database: analyses, apps, tools, users, subscriptions |
| `notifications` | Notification records |
| `metadata` | Metadata templates and AVUs |
| `qms` | Quota/subscription management (if QMS enabled) |
| `keycloak` | Keycloak user and realm data |

### Taking a manual backup

The `big_dumper.yml` playbook copies production to staging. For a one-off backup of a single
database to a local file:

```bash
pg_dump -h $DBMS_HOST -U de -d de -Fc -f de-backup-$(date +%Y%m%d).dump
```

`-Fc` produces a compressed custom-format dump that can be restored with `pg_restore`. To
restore:

```bash
pg_restore -h $DBMS_HOST -U de -d de de-backup-20260101.dump
```

> **Warning:** Restoring over a live database replaces all data. Only do this in a recovery
> scenario after stopping the DE services.

### Running a migration manually

If the automated `setup-databases` pass fails partway through, you can run migrations
manually with the `migrate` tool:

```bash
# Ensure migrate is on your PATH
# Check out the migration repo if needed
git clone https://github.com/cyverse-de/de-database /tmp/de-database

migrate \
  -database "postgresql://de:$DBMS_PASS@$DBMS_HOST:5432/de?sslmode=disable" \
  -path /tmp/de-database/migrations \
  up
```

For `notifications` and `metadata`:

```bash
git clone https://github.com/cyverse-de/notifications-db /tmp/notifications-db
migrate \
  -database "postgresql://de:$DBMS_PASS@$DBMS_HOST:5432/notifications?sslmode=disable" \
  -path /tmp/notifications-db/migrations \
  up

git clone https://github.com/cyverse-de/metadata-db /tmp/metadata-db
migrate \
  -database "postgresql://de:$DBMS_PASS@$DBMS_HOST:5432/metadata?sslmode=disable" \
  -path /tmp/metadata-db/migrations \
  up
```

To check the current migration version:

```bash
migrate \
  -database "postgresql://de:$DBMS_PASS@$DBMS_HOST:5432/de?sslmode=disable" \
  -path /tmp/de-database/migrations \
  version
```

### Useful diagnostic queries

Connect to the `de` database (see above), then:

```sql
-- Active database connections (check for connection pool exhaustion)
SELECT count(*), state, application_name
FROM pg_stat_activity
GROUP BY state, application_name
ORDER BY count DESC;

-- Find long-running queries (potential locks or runaway queries)
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > INTERVAL '5 minutes';

-- Database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE datistemplate = false
ORDER BY pg_database_size(datname) DESC;

-- Largest tables in the current database
SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;
```

For job/analysis-specific queries (stuck analyses, per-user lookups, status counts), see
[batch-analyses-troubleshooting.md](batch-analyses-troubleshooting.md) §1 and §8.

### Rotating the database password

If `dbms_connection_pass` needs to change:

1. Update `dbms_connection_pass` in the private inventory.
2. Change the password in PostgreSQL:
   ```sql
   ALTER ROLE de WITH PASSWORD '<new-password>';
   ```
3. Push new service configs and restart services:
   ```bash
   ansible-playbook -i /path/to/inventory --tags=configure-services kubernetes.yml
   kubectl -n $NS rollout restart deployment --all
   ```
