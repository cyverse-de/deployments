---
type: Service
title: PostgreSQL
description: How PostgreSQL is installed and the DE databases are initialized by the install-postgres and setup-databases passes of kubernetes.yml, plus day-to-day operations such as backups, manual migrations, and diagnostics.
resource: /docs/postgresql.md
tags: [postgresql, database, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

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
`PATH`. See `docs/index.md` for tool requirements.

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

## Day-to-day database operations

PostgreSQL runs on the `dbms` inventory host, not as a Kubernetes service, and is
typically reachable directly from operator workstations (or via VPN). Connect with
`psql -h <dbms-host> -U de -d <database>`, authenticating with
`dbms_connection_pass` from the inventory. The databases are:

| Database        | Purpose                                                    |
| --------        | -------                                                    |
| `de`            | Main DE database: analyses, apps, tools, users, subscriptions |
| `notifications` | Notification records                                       |
| `metadata`      | Metadata templates and AVUs                                |
| `qms`           | Quota/subscription management (if QMS enabled)             |
| `keycloak`      | Keycloak user and realm data                               |

### Backups

For a one-off backup of a single database, use a compressed custom-format dump:

```bash
pg_dump -h $DBMS_HOST -U de -d de -Fc -f de-backup-$(date +%Y%m%d).dump
```

Restore with `pg_restore -h $DBMS_HOST -U de -d de <dump-file>`. Restoring over a
live database replaces all data — only do this in a recovery scenario after
stopping the DE services.

### Running migrations manually

If the `setup-databases` pass fails partway through, migrations can be applied
directly with the `migrate` tool against the appropriate database. The migration
repositories are `cyverse-de/de-database` (for `de`), `cyverse-de/notifications-db`,
and `cyverse-de/metadata-db`:

```bash
git clone https://github.com/cyverse-de/de-database /tmp/de-database
migrate \
  -database "postgresql://de:$DBMS_PASS@$DBMS_HOST:5432/de?sslmode=disable" \
  -path /tmp/de-database/migrations \
  up
```

Substitute `version` for `up` to check the current migration version.

### Diagnostic queries

Useful queries against `pg_stat_activity` and the catalog tables (full SQL in
`docs/postgresql.md`):

* connection counts grouped by `state` and `application_name` — checks for
  connection pool exhaustion,
* queries running longer than 5 minutes — finds locks and runaway queries,
* `pg_database_size` / `pg_total_relation_size` — database and table sizes.

For job/analysis-specific queries (stuck analyses, per-user lookups, status
counts), see [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md).

### Rotating the database password

1. Update `dbms_connection_pass` in the private inventory.
2. `ALTER ROLE de WITH PASSWORD '<new-password>';` in PostgreSQL.
3. Push new service configs and restart services:
   `ansible-playbook -i /path/to/inventory --tags=configure-services kubernetes.yml`
   followed by `kubectl -n $NS rollout restart deployment --all`.

# Citations

[1] `docs/postgresql.md` — source document for this page, including the full diagnostic SQL.
[2] `ansible/roles/postgresql/`, `ansible/roles/postgresql_access/`, `ansible/roles/postgresql_init/` — roles run by the two passes.
[3] `ansible/example/inventory/group_vars/all.yaml` — annotated reference of overridable variables.
