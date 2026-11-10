---
type: Playbook
title: AI Sandbox Authenticator Keycloak Setup
description: Admin-console steps to wire the ai-sandbox-authenticator into a first-login flow — flow setup, IdP/OIDC requirements, theme assignment.
resource: /ansible/roles/keycloak_install
tags: [ai-sandbox-authenticator, keycloak, authentication, oidc, idp, first-login-flow]
timestamp: 2026-11-06T00:00:00Z
---

This is manual admin-console configuration — it is **not** applied by
Ansible and does not live in this repo. It covers what has to be set up once
per realm/client for [ai-sandbox-authenticator](/services/ai-sandbox-authenticator.md)
to run. See [Keycloak](/infrastructure/keycloak.md) for general admin access
and client/secret management.

> **Verify against the current realm before relying on this page** — it
> describes the standard Keycloak mechanism the authenticator's code assumes
> (`AbstractIdpAuthenticator`, broker first-login flow, `EXISTING_USER_INFO`
> auth note), not a step-by-step transcript of how the realm is actually
> configured today. Confirm flow names and bindings in **Authentication**
> before changing anything.

## 1. IdP (university IdP) requirements

The authenticator reads `getEmail`, `getFirstName`, `getLastName`, and
`getModelUsername` off the broker's `BrokeredIdentityContext`, and checks
`isTransientUsers` on the IdP config (transient users are rejected outright).
This means the Identity Provider entry for the university IdP (**Identity
Providers** in the realm) must:

- Be a non-transient provider (**Store Tokens** / standard account linking,
  not "transient users").
- Map `email`, `given_name`/`first_name`, and `family_name`/`last_name` from
  the IdP's claims — via OIDC scopes (`openid email profile` at minimum) or
  SAML attribute mappers, whichever protocol the university IdP speaks — onto
  the corresponding Keycloak broker fields (**Mappers** tab on the IdP).
  Without an email claim the authenticator can't do collision checks at all.
- Have **First Login Flow** (on the IdP's **Settings** tab) set to the
  custom flow built in step 2, not Keycloak's default.

## 2. Building the first-login flow

1. **Authentication** → **Flows** → duplicate `First Broker Login` (don't
   edit the built-in flow directly) → name it e.g. `AI Sandbox First Broker
   Login`.
2. In the duplicated flow, find the "Create User If Unique" execution (or
   equivalent default) and either disable it or remove it — it must not run
   instead of, or before conflicting with, this authenticator.
3. Add execution → **AI Sandbox - Create User** (display name from
   `factory-getDisplayType`, provider id `ai-sandbox-create-user`). Set its
   requirement to **ALTERNATIVE** or **REQUIRED** depending on whether this
   IdP ever needs the stock Keycloak behavior as a fallback — the
   authenticator's own early-exit (`.attempted`) already defers to Keycloak's
   built-in "Handle Existing Account" sub-flow when it detects a Keycloak-side
   email collision, so that sub-flow should remain downstream in the same
   flow, not be replaced.
4. Click the gear icon on the new execution → **Config** → fill in
   `portalConductorUrl`, `portalConductorUsername`, `portalConductorPassword`,
   and optionally `portalConductorInsecure` / `subscriptionPlan` (see
   [ai-sandbox-authenticator](/services/ai-sandbox-authenticator.md#configuration)
   for what each does). These are realm/flow-execution config, entered
   directly in the console — they are not pushed by Ansible and are not
   secrets managed elsewhere in this repo.
5. Set the IdP's **First Login Flow** (step 1) to this new flow.

## 3. Login theme

The `ai-sandbox` theme (packaged into the Keycloak image from this
authenticator's `resources/theme/ai-sandbox`) supplies the username-selection
page (`ai-sandbox-username-selection.ftl`) the authenticator challenges to
when it needs the user to pick a different username. Set it on the client
used by [ai-sandboxes-ui](/services/ai-sandboxes-ui.md) (the client whose id
is `ai2s_keycloak_client_id`, default `ai-sandboxes`) under that client's
**Advanced** tab → **Login Theme Override**, if the realm's default login
theme isn't already `ai-sandbox`. Confirm the theme is listed under
**Realm Settings** → **Themes** (it should appear automatically once the
image containing it is deployed — see
[ai-sandbox-authenticator's packaging](/services/ai-sandbox-authenticator.md)).

## 4. Testing

1. Use a test university-IdP account with an email not already in Keycloak
   or the Portal DB.
2. Log in through [ai-sandboxes-ui](/services/ai-sandboxes-ui.md) and confirm
   a new account is created in Keycloak and, via
   [portal-conductor](/services/portal-conductor.md), in the Portal DB/LDAP/iRODS.
3. Re-run with an email that already has a Portal DB account but no Keycloak
   user, to exercise the "admin intervention required" failure path.
4. Re-run with a username collision to confirm the username-selection form
   renders using the `ai-sandbox` theme.

## Troubleshooting

- **Authenticator fails every login with an internal server error:**
  `portalConductorUrl` is unset or wrong — check the execution's Config
  (step 2.4) and `portal-conductor`'s reachability from Keycloak's pod.
- **New Keycloak accounts are created but users land back at an error
  page:** `portal-conductor` created the user in LDAP but Keycloak's LDAP
  federation hasn't synced yet. Check LDAP federation sync settings per
  [Keycloak](/infrastructure/keycloak.md).
- **Username selection form never appears / wrong theme shown:** confirm the
  client's Login Theme Override (step 3) and that the deployed Keycloak
  image actually contains the `ai-sandbox` theme (rebuild
  `cyverse-de/keycloak-image` if the authenticator repo changed its theme).

# Citations

[1] `src/org/cyverse/ai/sandboxes/broker/authenticator.clj` (ai-sandbox-authenticator) — broker fields read, transient-user check, email/username collision handling, `EXISTING_USER_INFO` deferral.
[2] `src/org/cyverse/ai/sandboxes/broker/factory.clj` (ai-sandbox-authenticator) — provider id, display name, config properties.
[3] [ai-sandbox-authenticator](/services/ai-sandbox-authenticator.md) — what the authenticator does and its config properties.
[4] [Keycloak](/infrastructure/keycloak.md) — admin console access, client/secret management.
