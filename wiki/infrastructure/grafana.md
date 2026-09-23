---
type: Service
title: Grafana
description: Optional metrics dashboards for the DE — a Helm-installed Grafana with a read-only PostgreSQL datasource on the DE database and a provisioned logins dashboard, installed only when the grafana tag is named explicitly, and optionally exposed through a Gateway with Keycloak login limited to DE admin groups.
resource: /ansible/roles/grafana
tags: [grafana, metrics, dashboards, observability, postgresql, keycloak, gateway-api, kubernetes.yml]
timestamp: 2026-09-22T00:00:00Z
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

By default Grafana is not exposed outside the cluster — no Certificate, no Gateway, no
HTTPRoute. Reach it by port-forwarding:

```bash
kubectl -n grafana port-forward svc/grafana 3000:80
```

Log in as `grafana_admin_user` / `grafana_admin_password` (both come from the `grafana-admin`
Secret via the chart's `admin.existingSecret`). That account is a bootstrap credential, not a
shared login: use it once to create real administrator accounts, then leave it alone.
Self-service signup is off (`grafana_allow_sign_up: false`) and anonymous access is disabled.

### External access through Keycloak

Setting `grafana_external_access: true` serves Grafana at `grafana_hostname` and adds
"Sign in with CyVerse", Grafana's `generic_oauth` login against the DE realm in
[Keycloak](/infrastructure/keycloak.md). The role then also creates:

- a `grafana-tls` Certificate in the `grafana` namespace — from a namespace-local CA with
  `cert_manager_provider: selfsigned`, from the Let's Encrypt ClusterIssuer otherwise (see
  [cert-manager](/infrastructure/cert-manager.md));
- a `grafana` Gateway with one HTTPS listener on 8443 and an HTTPRoute to the `grafana`
  Service, the same shape as Keycloak's own Gateway (see
  [Ingress and Gateway Routing](/infrastructure/ingress.md));
- a `grafana-oauth` Secret holding `grafana_keycloak_client_secret`, injected as
  `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` so it stays out of the `grafana.ini` ConfigMap.

[HAProxy](/infrastructure/haproxy.md) passes 443 through to Traefik untouched, so the only
change outside Kubernetes is a DNS record for `grafana_hostname` pointing at the proxy.

Who gets in is decided by the `entitlement` claim — the same bare LDAP group names terrain
checks for the DE admin pages. `grafana_oauth_allowed_groups` defaults to `admin_groups`;
a user whose claim contains none of them is refused at login. Everyone admitted gets
`grafana_oauth_default_role` (Viewer) unless they are in `grafana_oauth_admin_groups`
(Admin) or `grafana_oauth_editor_groups` (Editor), checked in that order. Both lists are
empty by default. Editor and Admin can use Explore, which means arbitrary SQL through the DE
datasource, so grant them deliberately.

Group membership and role are only evaluated at login. Someone removed from an allowed
group keeps their Grafana session until it ends, which `grafana_login_maximum_lifetime_duration`
caps at 10 hours (Grafana's own default is 30 days).

The Keycloak client (`grafana_keycloak_client_id`, default `grafana`) is created by
`keycloak_config`, which only runs from `local.yml`. In QA and production create it by hand
in the DE realm: a confidential client with the standard flow enabled, redirect URI
`https://<grafana_hostname>/*`, and web origin `https://<grafana_hostname>`. The `profile`
client scope already carries the `entitlement` mapper, so nothing else is needed. Copy its
secret into `grafana_keycloak_client_secret`.

If Keycloak serves a certificate Grafana does not trust, the token exchange fails after the
Keycloak login page. `grafana_oauth_tls_skip_verify: true` works around that for a
self-signed test deployment only.

The local login form stays available, so the bootstrap admin remains a way in if Keycloak is
down. Accounts created by hand before external access was enabled are not merged with the
Keycloak identities.

## Where the datasource is (there is no picker)

The DE datasource is provisioned from the role, and the dashboards pin it per
panel. A datasource picker only appears in a dashboard's top bar when the
dashboard declares a `datasource`-type template variable, and DE Logins declares
only `bucket` — so the top bar shows Bucket and the time range, and nothing else.
That is deliberate: the dashboard's SQL is specific to the DE schema, so a picker
whose only valid value is DE would be worse than none.

To see or change which datasource a panel uses:

- **Per panel** — hover the panel title and press `e`, or use the panel menu →
  Edit. The Query tab shows the datasource, reading "DE".
- **Whole dashboard** — Dashboard settings (gear) → JSON Model.
- **The datasource itself** — Connections → Data sources → DE. It is marked
  "Provisioned" and the fields are read-only, because it comes from the role's
  config rather than the UI. Do not create a second PostgreSQL datasource by hand;
  edit the role instead.

One trap worth knowing, because it cost a debugging session: in the provisioning
file the database name must go under `jsonData` (`jsonData.database`), **not** at
the top level of the datasource entry. A top-level `database:` populates only the
deprecated `data_source.database` column. Grafana's backend falls back to that
column, so `/api/ds/query` and the datasource health check both pass — but the UI
reads `jsonData.database`, so the datasource appears to have no database and can't
be used from a dashboard. A green health check does not prove the datasource is
usable; assert on `jsonData` instead:

```bash
curl -s -u admin:<password> http://localhost:3000/api/datasources/uid/de-postgres \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["jsonData"])'
```

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
[2] `ansible/roles/grafana/tasks/main.yml` — namespace, secrets, dashboard ConfigMap, Helm values, readiness wait, and the optional Keycloak login, Certificate, Gateway, and HTTPRoute.
[3] `ansible/roles/grafana/files/dashboards/de-logins.json` — the DE Logins dashboard.
[4] `ansible/grafana.yml` — the standalone deployment playbook.
[5] `ansible/kubernetes.yml` — the `grafana` tag and its `ansible_run_tags` guard.
[6] `ansible/roles/postgresql_init/tasks/grafana.yml` — the state database and the two roles, including the read-only grants.
[7] `ansible/roles/common/defaults/main.yml` — the `grafana` enable flag, the `grafana_db_*` / `grafana_ro_db_*` variables, and `grafana_external_access` with its hostname and Keycloak client.
[8] `apps/src/apps/persistence/users.clj` — `upsert-login-record`, the only writer of `logins`.
[9] `ansible/roles/keycloak_config/defaults/main.yml` — `keycloak_config_grafana_client`, the Keycloak client for local deployments.
