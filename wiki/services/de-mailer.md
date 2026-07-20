---
type: Service
title: de-mailer
description: Sends DE email notifications, building links from the DE base URL and relaying through an in-cluster Exim SMTP host.
resource: /ansible/roles/services/de-mailer
tags: [email, smtp, notifications, de]
timestamp: 2026-07-20T00:00:00Z
---

de-mailer is the DE's outbound email service (its config file is named
`emailservice.yml`, and other services reach it via `baseurls_iplant_email`,
which points at `http://de-mailer`). The config is small: the DE base URL plus
the UI path fragments (`/analyses`, `/apps`, `/data/ds`, `/vice`, etc.) used
to construct links in email bodies, the `From:` address (`email_src`), and the
SMTP relay host, which is hardcoded to `local-exim` — an Exim service expected
to exist in the cluster.

- Source: [cyverse-de/de-mailer](https://github.com/cyverse-de/de-mailer); image `harbor.cyverse.org/de/de-mailer` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `emailservice.yml.j2` is templated into the `de-mailer-configs` secret and mounted at `/etc/iplant/de/emailservice.yml`. Notable vars: `de_base_uri`, `email_src`.
- Runtime: 2 replicas by default (`de_mailer_replicas`, no anti-affinity setting in this role); listens on port 8080 behind a ClusterIP Service on port 80; OpenTelemetry tracing to [Jaeger](/infrastructure/jaeger.md) is wired via the `configs` secret.

Unlike most service roles, it has no direct database or messaging
connections — everything arrives over HTTP and leaves over SMTP.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags de-mailer` —
see [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/de-mailer/templates/emailservice.yml.j2` — DE base URL, path fragments, from-address, `local-exim` SMTP host.
2. `ansible/roles/services/de-mailer/files/de-mailer.json` — pinned image name and digest.
3. `ansible/roles/services/de-mailer/templates/k8s/de-mailer.yml.j2` — Deployment/Service, port 8080, probes.
4. `ansible/roles/services/de-mailer/tasks/main.yml` — creates the `de-mailer-configs` secret, then runs deploy-service.
5. `ansible/roles/common/defaults/main.yml` — `baseurls_iplant_email: http://de-mailer` and `email_src`.
