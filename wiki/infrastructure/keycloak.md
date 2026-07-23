---
type: Service
title: Keycloak
description: Keycloak administration for the DE — deployment, health checks, client secret rotation, admin users, impersonation, and diagnosing authentication failures.
resource: /docs/keycloak.md
tags: [keycloak, authentication, oidc, ldap, secrets, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

Keycloak handles all DE authentication. This page covers common administration tasks:
checking health, managing clients and secrets, adding admin users, rotating credentials,
and diagnosing authentication failures.

## Overview

Every service that validates user tokens or calls a protected API uses a Keycloak client
configured for the DE realm. The key clients are:

| Client | ID variable | Secret variable | Used by |
|---|---|---|---|
| DE (terrain) | `keycloak_client_id` | `keycloak_client_secret` | [terrain](/services/terrain.md) (user token validation, API calls) |
| VICE services | `keycloak_vice_client_id` | `keycloak_vice_client_secret` | [app-exposer](/services/app-exposer.md), [async-tasks](/services/async-tasks.md), job-status-\*, and most Go services |
| DE admin | `keycloak_admin_client_id` | `keycloak_admin_client_secret` | terrain admin API calls to Keycloak |
| VICE API | `vice_api_keycloak_client_id` | `vice_api_keycloak_client_secret` | [vice-operator](/services/vice-operator.md) API authentication |
| VICE operator | `vice_operator_keycloak_client_id` | `vice_operator_keycloak_client_secret` | vice-operator internal auth |
| Portal/formation | `formation_keycloak_client_id` | `formation_keycloak_client_secret` | [portal-conductor](/services/portal-conductor.md) |

All of these flow through Ansible inventory variables into Kubernetes Secrets, which are
mounted into the service pods as config files.

## Deployment

Keycloak is installed by the `keycloak_install` role, which runs in `kubernetes.yml` under
the `keycloak` tag. The role is gated on the tag being requested explicitly, so a plain
`kubernetes.yml` run skips it:

```bash
ansible-playbook -i /path/to/inventory --tags=keycloak kubernetes.yml
```

The role (see `ansible/roles/keycloak_install/tasks/main.yml`):

- Creates the `keycloak_namespace` namespace (default: `keycloak`) and a `dbuser` Secret
  from `keycloak_db_username` / `keycloak_db_password`; the database host is the first
  member of the `[dbms]` inventory group — see [PostgreSQL](/infrastructure/postgresql.md).
- Provisions the `kc-tls` certificate via cert-manager. With
  `cert_manager_provider: selfsigned` it first creates a `kc-selfsigned-ca` CA Certificate
  and a `kc-ca-issuer` Issuer; with `letsencrypt` it issues `kc-tls` for
  `keycloak_hostname` from the Let's Encrypt ClusterIssuer. Durations come from
  `keycloak_cert_duration` (1 year) and `keycloak_cert_renew_before` — see
  [Certificate Management](/playbooks/certificate-management.md).
- Deploys a single-replica Deployment running
  `harbor.cyverse.org/de/keycloak:{{ keycloak_version }}` (`keycloak_version` default and
  supported values are in `ansible/roles/common/defaults/main.yml`), with health probes on
  the management port 9000, plus a ClusterIP Service exposing port 8080 as port 80.
- Creates a Gateway (class `gateway_class_name`, HTTPS listener on 8443 using `kc-tls`)
  and an HTTPRoute for `keycloak_hostname` — see [Ingress](/infrastructure/ingress.md).
- Creates the permanent admin account (`keycloak_admin_username` /
  `keycloak_admin_password` / `keycloak_admin_email`) via a one-shot `create-kc-admin.sh`
  Job that authenticates as the temporary bootstrap admin
  (`keycloak_temp_admin_username` / `keycloak_temp_admin_password`), then deletes the Job
  and the transient `kcadmin` Secret.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf
export NS=prod
export KEYCLOAK_NS=keycloak
export KEYCLOAK_URL=https://auth.cyverse.org    # or your deployment's keycloak_hostname
export REALM=CyVerse                             # or keycloak_realm_name
```

## 1. Verify Keycloak is running and healthy

```bash
kubectl -n $KEYCLOAK_NS get pods
kubectl -n $KEYCLOAK_NS describe pod <keycloak-pod>
```

Keycloak exposes a health endpoint on its management port (9000). The application port
(8080) serves the UI and auth endpoints; the Kubernetes Service exposes it on port 80.

```bash
# Port-forward directly to the pod's management port for health checks
KC_POD=$(kubectl -n $KEYCLOAK_NS get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
kubectl -n $KEYCLOAK_NS port-forward $KC_POD 9000:9000 &
curl -s http://localhost:9000/auth/health/ready | jq .
```

A healthy response looks like:
```json
{"status": "UP", "checks": [...]}
```

### Check Keycloak logs

```bash
kubectl -n $KEYCLOAK_NS logs -l app=keycloak --since=1h | grep -i "error\|warn\|exception"
```

## 2. Access the Keycloak admin console

The admin console is at `$KEYCLOAK_URL/auth/admin` (note the `/auth` context path used by
the DE's Keycloak image).

Credentials are set by:
- `keycloak_admin_username` (default: `kcadmin`) — the permanent admin account
- `keycloak_admin_password` — set in the private inventory

> **Do not use the temporary admin account** (`keycloak_temp_admin_username: admin`) for
> routine operations. It exists only for the initial bootstrap and should be disabled or
> have its password rotated after setup.

If you need to log in via the admin CLI (for scripted operations):

```bash
# Get an admin token
ADMIN_TOKEN=$(curl -s -X POST \
  "$KEYCLOAK_URL/auth/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$KEYCLOAK_ADMIN_USER" \
  -d "password=$KEYCLOAK_ADMIN_PASS" \
  -d "grant_type=password" | jq -r '.access_token')
```

## 3. Rotate a Keycloak client secret

Client secrets are set in the Keycloak admin console and then mirrored into the Ansible
inventory, from which they are pushed to Kubernetes Secrets and service config files.

### Step 1 — Regenerate the secret in Keycloak

1. Log in to the admin console (`$KEYCLOAK_URL/admin`).
2. Navigate to **Realm Settings** → **Clients**.
3. Select the client (e.g., the client matching `keycloak_client_id`).
4. Go to the **Credentials** tab.
5. Click **Regenerate** next to the Client secret.
6. Copy the new secret value.

### Step 2 — Update the inventory

In the private inventory repository, update the corresponding variable in
`inventory/group_vars/all.yaml` (or the appropriate host/group vars file):

```yaml
keycloak_client_secret: <new-secret>
# or
keycloak_vice_client_secret: <new-secret>
```

### Step 3 — Push the new secret to Kubernetes and redeploy

Run the `configure-services` tag to render and push the new config Secrets, then restart
the affected services:

```bash
ansible-playbook -i /path/to/inventory --tags=configure-services kubernetes.yml
```

Then restart only the services that actually use the rotated client. See the table below
to determine which services to restart.

### Which variable maps to which client and services

| Inventory variable | Keycloak client | Services to restart |
|---|---|---|
| `keycloak_client_secret` | `keycloak_client_id` | terrain, formation |
| `keycloak_admin_client_secret` | `keycloak_admin_client_id` | terrain |
| `keycloak_vice_client_secret` | `keycloak_vice_client_id` | app-exposer |
| `vice_api_keycloak_client_secret` | `vice_api_keycloak_client_id` | app-exposer, vice-operator |
| `vice_operator_keycloak_client_secret` | `vice_operator_keycloak_client_id` | vice-operator |
| `formation_keycloak_client_secret` | `formation_keycloak_client_id` | portal-conductor |

> **Note:** The `keycloak_vice_client_secret` is included in the shared `jobservices.yml`
> config file which is deployed to many services, but only app-exposer actually reads it.
> You only need to restart services that consume the credentials — not every service that
> receives the config file.

Example restart for `keycloak_client_secret`:

```bash
kubectl -n $NS rollout restart deployment/terrain deployment/formation
```

Example restart for `keycloak_vice_client_secret`:

```bash
kubectl -n $NS rollout restart deployment/app-exposer
```

## 4. Add or modify an admin user

Admin access to the DE is controlled by the `admin_groups` inventory variable (set in
`terrain.authz.allowed-groups`), which is a comma-separated list of LDAP group names
(default: `core-services,dev,staff`). Terrain checks the `entitlement` claim in the user's
JWT — this claim is populated by Keycloak's LDAP federation from the user's LDAP group
memberships (see [LDAP](/infrastructure/ldap.md)).

To grant admin access, add the user to one of the configured LDAP groups. This is done
through your LDAP directory management tools (e.g., `ldapmodify`, an LDAP admin UI, or
whatever tool manages your directory). After the next Keycloak LDAP sync (or the user's
next login), the `entitlement` claim in their token will include the group and they will
have admin access.

## 5. Diagnose authentication failures

### Symptoms and first steps

**All users can't log in:**

```bash
# Check Keycloak is up
kubectl -n $KEYCLOAK_NS get pods
kubectl -n $KEYCLOAK_NS logs -l app=keycloak --since=15m | grep -i error

# Check terrain is reaching Keycloak
kubectl -n $NS logs -l de-app=terrain --since=15m | grep -i "keycloak\|auth\|token\|401\|403"
```

**One user can't log in:**

Common causes:
- User doesn't exist in the realm (check Keycloak Users list)
- User account is disabled
- User's LDAP sync has failed (if using LDAP federation)

**API calls returning 401/403:**

First establish whether it is an expired token, wrong client, or a scope/audience issue:

```bash
# Check terrain logs for the specific error
kubectl -n $NS logs -l de-app=terrain --since=30m | grep -i "401\|403\|unauthorized\|forbidden"
```

A `401` from terrain usually means the user's token has expired. A `403` usually means the
user lacks a required group membership (check `admin_groups`).

### Check whether a client secret has drifted

If services are logging `unauthorized_client` or `invalid_client` errors, the client
secret in Kubernetes may no longer match what's in Keycloak. Compare:

```bash
# Get the secret currently deployed in Kubernetes
kubectl -n $NS get secret terrain-configs -o jsonpath='{.data.terrain\.properties}' | \
  base64 -d | grep client-secret
```

Compare to what is in the Keycloak admin console (**Clients → [client] → Credentials**).
If they differ, follow the rotation procedure in §3.

### Check LDAP federation (if user accounts come from LDAP)

```bash
# In Keycloak admin console:
# Identity Providers → User Federation → <your LDAP provider> → Synchronize All Users
```

Or via the API:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/auth/admin/realms/$REALM/user-storage/<provider-id>/sync?action=triggerFullSync"
```

## 6. Force-refresh a user's session

If a user is stuck with a bad session (e.g., after a password change), you can invalidate
all their active sessions:

1. In the Keycloak admin console, go to **Users** → find the user → **Sessions** tab.
2. Click **Logout all sessions**.

Or via the admin API:

```bash
USER_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/auth/admin/realms/$REALM/users?username=<username>" | \
  jq -r '.[0].id')

curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/auth/admin/realms/$REALM/users/$USER_ID/logout"
```

## 7. Keycloak certificate expiry

Keycloak itself has a TLS certificate managed by cert-manager. If it expires, Keycloak
becomes unreachable and all DE authentication fails.

```bash
kubectl -n $KEYCLOAK_NS get certificates
kubectl -n $KEYCLOAK_NS describe certificate <keycloak-cert>
```

Renew following the same procedure as in
[Certificate Management](/playbooks/certificate-management.md).

## 8. Keycloak version upgrades

Keycloak version is controlled by `keycloak_version` in the inventory. Supported values
are documented in `ansible/roles/common/defaults/main.yml` (currently `26.5` and `26.6`;
only versions available in `harbor.cyverse.org/de/keycloak` are supported).

To upgrade:

1. Update `keycloak_version` in the inventory.
2. Run the `keycloak` tag:
   ```bash
   ansible-playbook -i /path/to/inventory --tags=keycloak kubernetes.yml
   ```
3. Watch the pod restart and become ready:
   ```bash
   kubectl -n $KEYCLOAK_NS rollout status deployment/keycloak
   ```
4. Verify the admin console and a test login work before declaring success.

> **Caution:** Keycloak major version upgrades (e.g., 25→26) may require a database
> migration that runs automatically on first start. Take a database backup before
> upgrading. See [PostgreSQL](/infrastructure/postgresql.md) for backup procedure.

## 9. Impersonate a user

When you need to see the DE exactly as a specific user sees it, or act as them within the
interface, you can use Keycloak's built-in user impersonation:

1. Log into the Keycloak admin console (the `keycloak_base_uri` from your inventory, at
   the `/admin/` path).
2. Switch to your DE realm (click the realm dropdown in the sidebar and select it).
3. Go to **Users**, search for the target user, and click their username.
4. Click **Action → Impersonate**.

After impersonation, navigating to the DE in the same browser will authenticate you as
that user. End the impersonation by logging out of the DE or signing back in as yourself.

> **Note:** Impersonation is logged in the Keycloak event log. Your admin account must
> have the `impersonation` role in the `realm-management` client to use this feature.

# Citations

[1] `docs/keycloak.md` — source document for this page.
[2] `ansible/roles/keycloak_install/tasks/main.yml` — role that deploys Keycloak (namespace, certs, Deployment, Gateway, admin bootstrap).
[3] `ansible/kubernetes.yml` — runs the `keycloak_install` role under the `keycloak` tag.
[4] `ansible/roles/common/defaults/main.yml` — default `keycloak_version` and certificate duration variables.
