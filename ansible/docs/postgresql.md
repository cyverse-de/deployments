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
