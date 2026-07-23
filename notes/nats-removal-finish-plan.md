# Finishing the NATS removal: migrate the usage-apis to HTTP

Scoping plan for retiring the DE's remaining NATS usage. Written 2026-07-23,
after terrain was migrated off NATS to the subscriptions HTTP API.

## Where things stand

The DE's NATS footprint is down to **three services**, all on the QMS
(`cyverse.qms.*`) subject tree:

- **subscriptions** — the NATS **server/responder**. QueueSubscribes to
  `cyverse.qms.>` and serves the full QMS subject set (user updates, usages,
  overages, summary, subscriptions, plans, quotas, users, add-ons). It only
  replies; it makes no outbound NATS calls. Backed by Postgres. It also already
  runs an Echo HTTP router exposing the same operations.
- **data-usage-api** — NATS **client** of subscriptions. Request/reply on
  `cyverse.qms.user.usages.get`, `cyverse.qms.user.overages.get`, and
  `cyverse.qms.user.updates.add` (pushes a `data.size` usage). Hot path: 2 of
  its 3 HTTP endpoints block on a QMS round-trip. Also has a trivial
  `cyverse.data.usage.ping`→`pong` health responder and a dead unused publish to
  `cyverse.qms.user.usages.add`. Uses NATS `JSON_ENCODER`.
- **resource-usage-api** — NATS **client** of subscriptions. Request/reply on
  the single subject `cyverse.qms.user.updates.add` (pushes a `cpu.hours` usage),
  fired per-analysis off AMQP job-status events. Uses a `protojson` encoder. It
  *already* also calls subscriptions over plain HTTP for `/summary/{user}`.

`qms` (older HTTP-only QMS backend) and `qms-adapter` (an AMQP→HTTP bridge) do
**not** use NATS at all.

After the terrain migration, the only remaining NATS callers are these two
usage-apis, and they use just **3 subjects**. Every other subject subscriptions
serves over NATS already has no caller. subscriptions exposes HTTP equivalents
for all three, so finishing the job is the same play used for terrain: point the
clients at HTTP, then retire the NATS server and infra.

## Target mapping (all three HTTP endpoints already exist and are in use)

| NATS subject | subscriptions HTTP endpoint | Caller(s) |
|---|---|---|
| `cyverse.qms.user.usages.get` | `GET /users/{username}/usages` | data-usage-api |
| `cyverse.qms.user.overages.get` | `GET /users/{username}/overages` | data-usage-api |
| `cyverse.qms.user.updates.add` | `PUT /user/{username}/updates` | data-usage-api + resource-usage-api |

`subscriptions` `AddUserUpdateHTTPHandler` binds the identical
`qms.AddUpdateRequest` both clients already build for NATS (username comes from
the path). The GET handlers return the same `UsageList` / `OverageList`
envelopes the NATS replies did. So these are transport-only changes over the
same message types.

## Phases (≈5–6 PRs)

### Phase 1 — resource-usage-api → HTTP (small; already half-migrated)
It already has a `--subscriptions-base-uri` flag (default `http://subscriptions`)
and an HTTP-client pattern (`internal/summarizer/httpsummarizer.go`), and only
one NATS call.

- Replace the `gotelnats.Request(..., subjects.QMSAddUserUpdate, ...)` in
  `cpuhours/cpuhours.go` with an HTTP `PUT {base}/user/{username}/updates`
  sending the `qms.AddUpdateRequest` body as JSON (reuse the summarizer client
  style).
- Delete the NATS connection setup in `main.go`, the `protojson` codec
  registration, the `natsClient` threading (`internal/internal.go`), and the
  `nats.go` / `gotelnats` / `go-mod/subjects` deps.
- Keep the AMQP job-status consumer and the existing HTTP `/summary` call.

### Phase 2 — data-usage-api → HTTP (medium; needs a new client)
It has no HTTP client to subscriptions today.

- Add a small HTTP client with three calls (usages GET, overages GET, updates
  PUT) and a `--subscriptions-base-uri` flag (default `http://subscriptions`).
  Use a pooled `http.Client` with an explicit timeout — `/current` and
  `/overage` are hot paths.
- Replace `natsconn/natsconn.go` usage in `api/lookup.go` and
  `db/coordination.go` with the HTTP client.
- Delete the NATS connection, the `cyverse.data.usage.ping` responder, the dead
  `cyverse.qms.user.usages.add` publish, and the NATS flags/config in `main.go`;
  drop the `nats.go` / `gotelnats` / `go-mod/subjects` deps.
- Keep AMQP (batch-update trigger) and ICAT/Postgres.
- Low payload risk: it already used Go's `JSON_ENCODER`, so field names already
  match subscriptions' `c.Bind`.

### Phase 3 — deployments: de-NATS the usage-api roles (small)
- `ansible/roles/services/data-usage-api/` and `.../resource-usage-api/`: remove
  the NATS volumes/mounts (`nats-client-tls`, `nats-services-creds`,
  `nats-configuration`) and the `DISCOENV_NATS_CLUSTER` / `NATS_URLS` env; wire
  the subscriptions base URL (`baseurls_subscriptions` already exists in
  `roles/common/defaults/main.yml`).
- Ships together with the Phase 1/2 images.

### Phase 4 — subscriptions: retire the NATS server (small–medium)
Safe once no clients call it (Phases 1–3 deployed).

- `subscriptions/main.go`: remove the NATS connection, the `cyverse.qms.>`
  `QueueSubscribe` loop, and the `natscl` client; keep the Echo HTTP router (the
  real API now). Remove `QMS_NATS_CLUSTER` handling.
- The ~23 NATS `*Handler` wrappers become dead — delete them; the HTTP twins and
  the shared private methods stay.
- deployments `roles/services/subscriptions/`: remove the NATS volumes/mounts,
  the `QMS_NATS_CLUSTER` env, and the `nats-configuration` mount.
- This is the point where NATS has zero DE consumers.

### Phase 5 — deployments: tear down the NATS infrastructure (medium)
- Remove the `nats` role from `ansible/kubernetes.yml` and uninstall the Helm
  release; delete the NATS namespace resources.
- Remove `nats_urls` (common defaults) and the `NATS_URLS` injection in
  `roles/service_configurations/tasks/main.yml`.
- Remove the NATS secrets / cert-manager Certificates the `nats` role creates
  (`nats-client-tls`, `nats-services-creds`, `nats-server-tls`; the
  `nats-client-tls-pkcs8` generation is already gone). Verify the nats-scoped
  `selfsigned-ca` / `ca-issuer` aren't shared before removing them.
- Wiki/docs: retire `wiki/infrastructure/nats.md`, drop the NATS section from
  Certificate Management (`wiki/playbooks/certificate-management.md` +
  `docs/certificate-management.md`), and update the full-deployment and
  ops-runbook pages. Run `okf index` + `okf check` to 0/0.

## Rollout order and safety

Phases 1–3 first (migrate + deploy the two clients), verify usage / overage /
update over HTTP in QA, **then** Phase 4 (subscriptions drops the server — safe
once no callers), **then** Phase 5 (infra teardown — safe once subscriptions no
longer subscribes). subscriptions serves both transports throughout, so each
client migration is independently deployable — there is no big-bang cutover.

Gate Phase 5 on verifying there are no remaining NATS consumers: no pods mount
the NATS secrets, and subscriptions is no longer subscribed.

## Risks and notes

- **Do NOT touch Argo Events' NATS.**
  `ansible/roles/argo/templates/argo_events_eventbus_install.yaml` is a
  `kind: EventBus` with its own `nats:` spec — a *separate* NATS instance managed
  by argo-events, unrelated to the DE `nats` Helm release. The Phase 5 teardown
  must leave it alone.
- **This migration resolves the dual-encoder wire mismatch.** Today
  data-usage-api (`JSON_ENCODER`) and resource-usage-api (`protojson`) hit the
  same `cyverse.qms.user.updates.add` subject with different encodings; once both
  are HTTP/`encoding-json`, that inconsistency disappears. Do verify
  resource-usage-api's update payload field casing against subscriptions' JSON
  tags (it currently sends camelCase protojson).
- **Latent nil-deref in subscriptions' `AddUserUpdateHTTPHandler`**: it does
  `request.Update.User.Username = c.Param(...)` before validating the nested
  object. The usage-apis always populate it, and the echo Recover middleware
  catches malformed input (→ 500), but a nil-guard is worth folding into Phase 4
  (same class of fix applied to the add-on handlers).
- subscriptions HTTP error codes are already correct (populated 4xx/5xx), so the
  clients get clean errors over HTTP — no status-0 workarounds needed.

## Rough effort

~1 week of focused work across ~5–6 PRs (two service repos + subscriptions + two
deployments PRs), shaped like the terrain migration. data-usage-api is the
largest single piece; resource-usage-api is a quick win to start with.
