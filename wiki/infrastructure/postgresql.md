---
type: Service
title: PostgreSQL
description: How PostgreSQL is installed and the DE databases are initialized by the install-postgres and setup-databases passes of kubernetes.yml, plus day-to-day operations such as backups, manual migrations, and diagnostics.
resource: /docs/postgresql.md
tags: [postgresql, database, kubernetes.yml]
timestamp: 2026-08-04T12:00:00Z
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
created. The Grouper, QMS, Harbor, Keycloak, User Portal, and
[Grafana](/infrastructure/grafana.md) databases are each created only when their
feature toggle is enabled.

The Grafana pass is the one that also grants privileges rather than just creating
a role and a database: alongside the `grafana` owner it creates a `grafana_ro`
role with `SELECT` on `public.logins` and `public.users` in the `de` database and
nothing else, which is what Grafana queries the DE data through.

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

`groups['dbms'][0]` is not only an Ansible target: it is interpolated verbatim
into every database URI the service config templates render, and so it has to
resolve inside pods. With a dedicated database host that is automatic, and the
control machine reaches the same name.

Where it does not — as in a
[local single-node deployment](/playbooks/local-single-node-deployment.md),
whose inventory hostname is a cluster DNS name backed by a selector-less
Service and EndpointSlice — set `db_login_host` (and `keycloak_db_login_host`)
to the address the control machine should use instead. Both default to their
`groups[...][0]` value, so an inventory that says nothing keeps the single-name
behaviour.

### Pre-flight locale check

A database's locale provider is fixed when it is created, so `postgresql_db`
cannot reconcile one that predates this role's move to `locale_provider: icu`:
it aborts with `Changing ICU_LOCALE is not supported`, which reads like a
permissions or version problem rather than a stale database. `postgresql_init`
checks `datlocprovider` up front and fails naming the offending databases. The
check runs only when `create_dbs` is set, so an environment that does not
create databases is unaffected by ones predating the switch.

Its scope is the runs that create databases, and nothing more. The check
carries no tags of its own, so it inherits the play's `setup-databases` and
`databases` and is filtered out of a `--tags update-databases` run — which is
correct, because every `postgresql_db` task it guards is untagged too and so
is filtered out of that run as well. Tagging the check would abort a
migrations-only pass over a locale mismatch that nothing in scope was going to
try to reconcile. This matters on an environment with a long-lived database
predating the switch: a `--tags update-databases` migration run against it
succeeds, while a full `setup-databases` pass still stops on the mismatch.
`grafana.yml` is the exception on the other side — its create task *is* tagged
`update-databases`, and `grafana_db_name` is absent from
`postgresql_init_managed_databases`, so it is neither checked nor deferred.

The check runs once per database server rather than once overall. Keycloak's
database is created against `keycloak_db_login_host`, which need not be
`db_login_host`, and a database that is not on the server being queried simply
does not come back in the result — so a single pass against one host would
report every database on the other as fine. `postgresql_init_preflight_targets`
pairs each host with the databases expected on it, and `local-teardown.yml`
drives its drops from the same structure for the same reason. Where both names
resolve to one server the second pass is redundant rather than wrong.

Roles are the subtler half of the same problem, because they outlive the
databases they own. `postgresql_user` reconciles only the attributes it is
given, so a role left over without `LOGIN` gets its password set correctly and
still cannot connect — Keycloak surfaces this as a crashloop on `password
authentication failed`. Every role this pass creates is therefore declared with
`role_attr_flags: LOGIN`.

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
| `grafana`       | Grafana's own state: accounts, API keys, dashboard edits (if Grafana enabled) |

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
