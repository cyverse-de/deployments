---
type: Service
title: portal2
description: The CyVerse user portal web application, handling account self-registration, sessions, and service access via Keycloak, portal-conductor, and terrain.
resource: /ansible/roles/services/portal2
tags: [portal, user-portal, nodejs, keycloak, accounts, security]
timestamp: 2026-08-27T00:00:00Z
---

The CyVerse user portal, a Node.js web application (`NODE_ENV=production`,
port 3000) deployed under the name `user-portal`. Its configuration wires it to
its own portal database on [PostgreSQL](/infrastructure/postgresql.md)
(including a session table), [Keycloak](/infrastructure/keycloak.md) for login
(`portal_keycloak_*`), [portal-conductor](/services/portal-conductor.md) for
account provisioning actions (with basic auth), and
[terrain](/services/terrain.md) with a service account for DE calls. It also
carries SMTP, Intercom, Sentry, Google Analytics, honeypot, and HMAC-key
settings. The source repo is
[cyverse-de/portal2](https://github.com/cyverse-de/portal2) and the image is
`harbor.cyverse.org/de/portal2`, pinned in
`ansible/roles/services/portal2/files/portal2.json`.

Configuration: the role renders `templates/portal2.json.j2` into the
`portal2-configs` secret (skipped when `load_configs` is false), mounted at
`/etc/cyverse/portal2/portal2.json` and located via `CONFIG_PATH`. Notable
group_vars: `portal_db_*`, `portal_session_*`, `portal_keycloak_*`,
`portal_conductor_url` and `portal_conductor_auth_*`, `portal_terrain_*`,
`portal_ui_base_url`, `portal_smtp_*`, and `portal_uid_number_offset`. The
`portal_disable_require_new_user_email_confirmation` flag (default `false`)
maps to `features.disableRequireNewUserEmailConfirmation` and, when `true`,
lets new accounts skip the email-confirmation step during self-registration.

Runtime: a Deployment with `portal2_replicas` (default 1), its own `timezone`
ConfigMap (America/Phoenix), a readiness probe on `/api/ready`, and a
`user-portal` Service on port 3000. Bootstrapping an initial admin account is
covered by [Bootstrap Portal Admin](/playbooks/bootstrap-portal-admin.md).

Build and deploy with
`ansible-playbook -i $INVENTORY deploy_it.yml --tags portal2`; see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Security audit follow-ups (deferred)

A security audit of portal2 shipped in six batches on the `security-audit`
branch during August 2026. The items below were deliberately **not** fixed and
remain open.

**CSRF — no synchronizer token.** The app relies on a `SameSite=Lax` session
cookie plus JSON-only body parsing (Express `bodyParser.json` ignores form
content-types) to block CSRF, which closes the practical vector. A
double-submit or per-session token would be defence in depth, but needs the
frontend to attach a token header to every mutating request. Related and
low-impact: logout CSRF via `GET /logout` (keycloak-connect) — under `Lax` a
top-level cross-site navigation still carries the cookie, so a page can
force-logout a user. Annoyance only; no data exposure.

**Per-IP rate limiting is best-effort.** The in-memory fixed-window limiter on
the public endpoints keys on Express's `req.ip` with `trust proxy` set to
`true`. In QA the edge forwards no usable client IP, so `req.ip` resolves to
cluster-internal addresses that vary per request, and the limiter never reaches
its budget; it is also per-replica. Making it real needs the edge to forward a
trustworthy `X-Forwarded-For`, `trust proxy` tightened to the known proxy hop
rather than any hop, and optionally a shared store (Redis or PostgreSQL) for a
cross-replica limit. Until then, treat the public rate limits as best-effort
and do not validate them in QA.

**Container hardening is partial.** The Deployment runs as the image's
non-root `nodejs` user (uid/gid 1001, matching the Dockerfile) with
`seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false` and all
capabilities dropped. It does **not** set `readOnlyRootFilesystem`: the custom
Next.js server may write `.next/cache` and `/tmp`, so writable `emptyDir`
mounts must be identified first. Note that a service's own source repo cannot
supply any of this — `templates/k8s/portal2.yml.j2` here is the only manifest
that reaches a cluster. It is rendered into `files/k8s/portal2.yml` at deploy
time (that path is generated and git-ignored), and the build overlays this
role's `k8s/` and `skaffold.yaml` onto the source worktree, so a
`k8s/portal2.yml` edited in the portal2 repo is discarded by both paths.

**Seven dependency advisories remain.** A non-breaking `npm audit fix` took the
count from 28 to 7. The rest need breaking major bumps — `next` (14 to newer,
which pulls `postcss`), `keycloak-connect` (via `jwk-to-pem` to `elliptic`),
and the `sequelize`/`uuid` chain — each wanting its own migration and
regression pass.

**Honeypot fake-field detection is inert.** The `honeypot: true` duplicate-field
mechanism was never wired up: no code read the flag and the client-side fake id
was unused. The audit removed the dead code and stopped exposing the divisor to
the client, but did not revive the detection. Revive it if bot signups become a
problem. `honeypot.divisor` is still validated at startup and must be a number
greater than 2.


# Citations

[1] `ansible/roles/services/portal2/templates/portal2.json.j2` — DB, Keycloak, portal-conductor, terrain, SMTP config.
[2] `ansible/roles/services/portal2/templates/k8s/portal2.yml.j2` — Deployment, Service, env, readiness probe.
[3] `ansible/roles/services/portal2/tasks/main.yml` — config secret rendering and deploy.
[4] `ansible/roles/services/portal2/files/portal2.json` — pinned image.
