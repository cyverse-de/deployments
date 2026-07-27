---
type: Service
title: Grafana
description: Optional metrics dashboards for the DE — a Helm-installed Grafana with a read-only PostgreSQL datasource on the DE database and a provisioned logins dashboard, installed only when the grafana tag is named explicitly.
resource: /ansible/roles/grafana
tags: [grafana, metrics, dashboards, observability, postgresql, kubernetes.yml]
timestamp: 2026-07-27T00:00:00Z
---

Grafana provides metrics dashboards for the DE. Like [Jaeger](/infrastructure/jaeger.md), it
is opt-in and off by default: the `grafana` role runs in the third-party-software play of
`kubernetes.yml` with `when: "'grafana' in ansible_run_tags"`, so a plain full run skips it.
There is also a standalone `grafana.yml` playbook.

Grafana is deployed from the upstream `grafana/grafana` Helm chart, pinned at
`grafana_chart_version` (10.5.15, app version 12.3.1).

## Installation

Grafana depends on two PostgreSQL databases' worth of setup, so the database initialization
has to run first. Set `grafana: true` in the inventory, then:

```bash
ansible-playbook -i <inventory> --tags setup-databases kubernetes.yml
ansible-playbook -i <inventory> --tags grafana kubernetes.yml
# or, for the deploy alone
ansible-playbook -i <inventory> grafana.yml
```

The `grafana` tag selects both halves, so `--tags grafana kubernetes.yml` will run the
database tasks and the deploy in one pass.

## State lives in PostgreSQL, not on a PVC

The chart is installed with `persistence.enabled: false`. Everything durable — accounts
created through the UI, API keys, dashboards edited in the browser — goes into a `grafana`
database on the `dbms` host, created by the [PostgreSQL](/infrastructure/postgresql.md)
`postgresql_init` role. Grafana manages its own schema on first startup, so there are no
migrations. The pod is disposable; deleting it loses nothing.

## Two database roles

`postgresql_init` creates two roles, and the separation is the point:

- `grafana_db_user` (default `grafana`) owns the `grafana` state database.
- `grafana_ro_db_user` (default `grafana_ro`) is what Grafana queries the DE database with.
  It gets `CONNECT` on `de`, `USAGE` on the `public` schema, and `SELECT` on exactly the
  tables in `grafana_ro_db_tables` (`logins` and `users`) — nothing else.

The read-only role matters because anyone holding the Grafana admin password can run
arbitrary SQL through the datasource's explore UI. Add a table to `grafana_ro_db_tables` when
a new dashboard needs it rather than widening the grant.

## Access

Grafana is not exposed outside the cluster — no Certificate, no Gateway, no HTTPRoute. Reach
it by port-forwarding:

```bash
kubectl -n grafana port-forward svc/grafana 3000:80
```

Log in as `grafana_admin_user` / `grafana_admin_password` (both come from the `grafana-admin`
Secret via the chart's `admin.existingSecret`). That account is a bootstrap credential, not a
shared login: use it once to create real administrator accounts, then leave it alone.
Self-service signup is off (`grafana_allow_sign_up: false`) and anonymous access is disabled.

## How the secrets stay out of ConfigMaps

The chart renders both `grafana.ini` and the datasource provisioning file into ConfigMaps, so
neither password can be handed to it literally. Both are injected as environment variables
from the `grafana-db` Secret instead: Grafana reads `GF_DATABASE_PASSWORD` for its own state
database, and expands `$__env{DE_DB_PASSWORD}` in the provisioning file at load time.

## Dashboards

Dashboards are plain JSON under `ansible/roles/grafana/files/dashboards/`, loaded into the
`grafana-de-dashboards` ConfigMap and mounted through the chart's `dashboardsConfigMaps` into
a file provider that puts them in a "Discovery Environment" folder. To change one, edit it in
the browser, export the JSON through Share → Export, and write it back over the file. The
provider polls, so a re-run of the role takes effect within a few seconds without a restart.

### DE Logins

The one dashboard so far. It reads `public.logins` in the DE database and shows total logins
and distinct users over the selected range, plus a time series of both bucketed by a `bucket`
variable (1h / 6h / 1d / 7d / 30d). Both series are counts per bucket, so they share one axis.

Two things about the data are worth knowing before trusting the numbers:

- **A row is a session, not a request.** The `apps` service writes `logins` rows when terrain
  handles `GET /secured/bootstrap`, upserting on the whole
  `(user_id, ip_address, session_id, login_time)` tuple, and `login_time` is the *Keycloak
  session start time* rather than the request time. Repeated bootstrap calls within one SSO
  session collapse to a single row, so a row is a good proxy for "a login."
- **The dashboard timezone is pinned to `utc` on purpose.** `logins.login_time` is a
  `timestamp without time zone` holding the database server's local wall clock
  (`America/Phoenix`) with no offset recorded. The queries read it literally
  (`login_time AT TIME ZONE 'UTC'`) so that a daily bucket is a database calendar day.
  Switching the dashboard to browser time would shift every bucket boundary — with true
  instant conversion, logins after 17:00 Phoenix land in the next day's bucket, because
  Grafana's `$__timeGroup` macro buckets on UTC midnight.

`logins` has no primary key and no indexes at all, so every panel refresh is a sequential
scan. That is fine at QA's scale and worth revisiting before pointing the dashboard at a
production-sized table.

# Citations

[1] `ansible/roles/grafana/defaults/main.yml` — namespace, chart version, bootstrap admin, and resource defaults.
[2] `ansible/roles/grafana/tasks/main.yml` — namespace, secrets, dashboard ConfigMap, Helm values, and readiness wait.
[3] `ansible/roles/grafana/files/dashboards/de-logins.json` — the DE Logins dashboard.
[4] `ansible/grafana.yml` — the standalone deployment playbook.
[5] `ansible/kubernetes.yml` — the `grafana` tag and its `ansible_run_tags` guard.
[6] `ansible/roles/postgresql_init/tasks/grafana.yml` — the state database and the two roles, including the read-only grants.
[7] `ansible/roles/common/defaults/main.yml` — the `grafana` enable flag and the `grafana_db_*` / `grafana_ro_db_*` variables.
[8] `apps/src/apps/persistence/users.clj` — `upsert-login-record`, the only writer of `logins`.
