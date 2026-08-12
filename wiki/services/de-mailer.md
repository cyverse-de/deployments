---
type: Service
title: de-mailer
description: Sends DE email notifications over HTTP and by consuming the email_requests AMQP queue, building links from the DE base URL and relaying through an in-cluster Exim SMTP host.
resource: /ansible/roles/services/de-mailer
tags: [email, smtp, amqp, rabbitmq, notifications, de]
timestamp: 2026-08-12T00:00:00Z
---

de-mailer is the DE's outbound email service. Requests reach it two ways:
other services POST to it over HTTP via `baseurls_iplant_email` (which points
at `http://de-mailer` — terrain, apps, and requests use this path), and it
consumes email-request messages directly from the durable `email_requests`
queue (routing key `email.requests`) on the `de` topic exchange of the DE
[RabbitMQ](/infrastructure/rabbitmq.md) broker. The AMQP role was absorbed
from the retired email-requests service, which used to forward those messages
to de-mailer over HTTP; [notifications](/services/notifications.md) is the only
publisher on that routing key, having absorbed it along with the rest of the
retired event-recorder. Failed AMQP deliveries are logged with their cause and acked (dropped),
matching the old chain's behavior.

Its config file is `emailservice.yml`: the DE base URL plus the UI path
fragments (`/analyses`, `/apps`, `/data/ds`, `/vice`, etc.) used to construct
links in email bodies, the `From:` address (`email_src`), the SMTP relay host
(hardcoded to `local-exim`), and the AMQP connection settings
(`de_amqp_*` vars, exchange `de`/`topic`). The service validates all of these
at startup and refuses to start if any is missing. local-exim is an Exim relay
deployed into the DE namespace by the `k8s_de_reqs` role, or on its own with
`local-exim.yml` (see
[Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md)).

local-exim is configured entirely from `exim_*` inventory variables, and their
role defaults are non-functional placeholders rather than sane fallbacks:
`exim_smarthost` defaults to loopback, which points exim at itself, and
`exim_allowed_senders` defaults to the Docker bridge network. The relay nets
are safe — the role prepends `k8s_pods_cidr` and `k8s_services_cidr` — but the
smarthost is not, so an environment that never set `exim_smarthost` accepts
mail from de-mailer and then fails to route it. Set `exim_smarthost` to the
real upstream relay in the inventory; `local-exim.yml` asserts this before
applying.

`exim_smarthost` is an exim host list, not a `host:port` pair: a single colon
separates hosts, so a port needs a second one (`mailgate.cyverse.org::25`).
`host:25` parses as two hosts and appends a bogus one named `25`, which exim
resolves to `0.0.0.25`. Mail still flows, since the real relay is tried first
on its default port, but a failover then stalls on the bogus host instead of
deferring cleanly.

The relay pods are not on `hostNetwork`, so they reach the upstream smarthost
SNAT'd as their node's IP — the smarthost's relay allowlist has to cover the
cluster nodes, and the Deployment has no node selector, so any node can end up
running one.

- Source: [cyverse-de/de-mailer](https://github.com/cyverse-de/de-mailer); image `harbor.cyverse.org/de/de-mailer` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `emailservice.yml.j2` is templated into the `de-mailer-configs` secret and mounted at `/etc/iplant/de/emailservice.yml`. Notable vars: `de_base_uri`, `email_src`, `de_amqp_*`.
- Runtime: 2 replicas by default (`de_mailer_replicas`, no anti-affinity setting in this role); listens on port 8080 behind a ClusterIP Service on port 80. The replicas are competing consumers on the shared durable queue. No OpenTelemetry — the embedded tracing was dropped when the AMQP consumer was absorbed.
- Cleanup: the role's tasks delete the retired `email-requests` Deployment and `email-requests-configs` Secret on deploy; those tasks are removable once every environment has rolled past the merge release.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags de-mailer` —
see [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/de-mailer/templates/emailservice.yml.j2` — DE base URL, path fragments, from-address, `local-exim` SMTP host, AMQP URI and exchange.
2. `ansible/roles/services/de-mailer/files/de-mailer.json` — pinned image name and digest.
3. `ansible/roles/services/de-mailer/templates/k8s/de-mailer.yml.j2` — Deployment/Service, port 8080, probes.
4. `ansible/roles/services/de-mailer/tasks/main.yml` — creates the `de-mailer-configs` secret, removes the retired email-requests leftovers, then runs deploy-service.
5. `ansible/roles/common/defaults/main.yml` — `baseurls_iplant_email: http://de-mailer`, `email_src`, `de_amqp_*`, and the placeholder `exim_*` defaults.
6. `ansible/roles/k8s_de_reqs/tasks/local_exim.yml` — the local-exim Deployment and Service, and how `EXIM_ALLOWED_SENDERS` is assembled from the cluster CIDRs.
7. `ansible/local-exim.yml` — standalone local-exim run with the smarthost assertion.
