---
type: Service
title: ai-sandbox-authenticator
description: Custom Keycloak first-login authenticator that creates CyVerse accounts for AI Sandbox users via portal-conductor, with Portal DB collision checks.
resource: /ansible/roles/keycloak_install
tags: [ai-sandbox-authenticator, keycloak, authentication, portal-conductor, ai-discovery-lab, ai-sandboxes-ui]
timestamp: 2026-11-06T00:00:00Z
---

A Clojure Keycloak provider (`ai-sandbox-create-user`) that runs as a step in
the first-login flow for [ai-sandboxes-ui](/services/ai-sandboxes-ui.md),
after the user authenticates with the university IdP. It handles the
account-creation half of federated login: checking for existing accounts and
creating new ones, since the platform's Portal DB predates Keycloak/LDAP and
can contain users Keycloak doesn't know about yet.

- **Source repo:** [cyverse-de/ai-sandbox-authenticator](https://github.com/cyverse-de/ai-sandbox-authenticator)
- **Packaging:** built into the [Keycloak image](/infrastructure/keycloak.md)
  (`harbor.cyverse.org/de/keycloak`) by `cyverse-de/keycloak-image`'s
  `Justfile`, which builds this repo's uberjar and copies its `ai-sandbox`
  login theme in at image-build time — there is no separate deploy for this
  component.

## What it does

On first login via the broker IdP:

1. Checks for an email collision — first against Keycloak, then (since
   Keycloak's LDAP federation may lag) against the Portal DB via
   `portal-conductor`'s `GET /portal/emails/{email}/exists`. A Keycloak-side
   collision defers to Keycloak's own account-linking sub-flow; a Portal-DB-only
   collision fails the login and tells the user to contact support — there's
   no automated path to link an account Keycloak hasn't seen.
2. Picks a candidate username from the IdP email's local part and validates
   it against the lowercase-alphanumeric format Portal accounts require,
   checking availability via Keycloak plus `portal-conductor`'s
   `GET /portal/users/{username}/exists`. On a collision or bad format, the
   `ai-sandbox` login theme's username-selection page prompts the user to
   pick another.
3. Creates the account with `portal-conductor`'s `POST /portal/users`, which
   fans out to LDAP, iRODS, and the Portal DB. Keycloak then finds the new
   user through its own LDAP federation and completes the login.

## Configuration

Configured per-execution in the Keycloak admin console, not through Ansible
variables — see [AI Sandbox Authenticator Keycloak Setup](/playbooks/ai-sandbox-authenticator-keycloak-setup.md)
for how to add it to a flow. Its execution config properties:

| Property | Required | Purpose |
|---|---|---|
| `portalConductorUrl` | yes | Base URL of [portal-conductor](/services/portal-conductor.md). Authenticator fails closed if unset. |
| `portalConductorUsername` / `portalConductorPassword` | yes | HTTP Basic Auth credentials for `portal-conductor`. |
| `portalConductorInsecure` | no | Skip TLS verification calling `portal-conductor`; not for production. |
| `subscriptionPlan` | no | QMS plan name assigned to newly created users; empty gets the default plan on first use. |

These point at the same `portal-conductor` instance and credentials already
used by [portal2](/services/portal2.md) — there is no separate
`portal_conductor_*` Ansible variable set aside for the authenticator; the
URL/credentials are entered directly into the authenticator's config in the
admin console.

## Deploying

No independent deploy: redeploying Keycloak (per
[Keycloak](/infrastructure/keycloak.md)) picks up a new build of this
provider because it's baked into the image. A code-only change requires
rebuilding `keycloak-image` and rolling Keycloak; a flow or config-property
change is made directly in the admin console per
[AI Sandbox Authenticator Keycloak Setup](/playbooks/ai-sandbox-authenticator-keycloak-setup.md)
and takes effect immediately, no redeploy needed.

# Citations

[1] `src/org/cyverse/ai/sandboxes/broker/authenticator.clj` — authenticator logic (collision checks, user creation).
[2] `src/org/cyverse/ai/sandboxes/broker/factory.clj` — provider id, display name, and config properties.
[3] `resources/theme/ai-sandbox/login/ai-sandbox-username-selection.ftl` — username selection form template.
[4] `resources/META-INF/keycloak-themes.json` — registers the `ai-sandbox` login theme.
