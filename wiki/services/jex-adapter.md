---
type: Service
title: jex-adapter
description: HTTP front door for batch analysis submissions, bridging the DE to the job-execution backend over AMQP and NATS.
resource: /ansible/roles/services/jex-adapter
tags: [batch, analyses, amqp, nats, jobservices, go]
timestamp: 2026-07-20T00:00:00Z
---

jex-adapter (JEX = Job EXecution) is part of the batch-analysis pipeline. It
exposes an HTTP API on port 60000 (in-cluster Service `jex-adapter` on port 80)
and talks to the rest of the job machinery over [RabbitMQ](/infrastructure/rabbitmq.md)
(the `de` topic exchange) and [NATS](/infrastructure/nats.md): the pod mounts
the `nats-client-tls` and `nats-services-creds` secrets and reads
`DISCOENV_NATS_CLUSTER` from the `configs` secret's `NATS_URLS` key. It also
connects to the DE database on [PostgreSQL](/infrastructure/postgresql.md) and
runs under the `configurator` service account.

- **Source repo:** [cyverse-de/jex-adapter](https://github.com/cyverse-de/jex-adapter)
- **Image:** `harbor.cyverse.org/de/jex-adapter` (built via the role's
  `files/skaffold.yaml`; the pinned tag/digest lives in
  `files/jex-adapter.json`)

## Configuration

The role renders the shared job-services template
`templates/jobservices.yml.j2` into the `jex-adapter-configs` secret, mounted
at `/etc/iplant/de/jobservices.yml`. The template covers far more than this
service consumes (AMQP, DE and notifications databases, [Condor](/infrastructure/condor.md)
settings, [iRODS](/infrastructure/irods.md), [Keycloak](/infrastructure/keycloak.md),
VICE, porklock image, and base URLs for [apps](/services/apps.md),
[metadata](/services/metadata.md), and [notifications](/services/notifications.md));
it is the same template used by the other job services. Tracing goes to
[Jaeger](/infrastructure/jaeger.md) via the OTEL variables in the `configs`
secret. Role defaults: `jex_adapter_replicas: 2` with required pod
anti-affinity; the container runs with `--log-level debug`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags jex-adapter
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/jex-adapter/files/jex-adapter.json` — image and pinned tag/digest.
2. `ansible/roles/services/jex-adapter/templates/jobservices.yml.j2` — shared job-services config (AMQP, DB, service URLs).
3. `ansible/roles/services/jex-adapter/templates/k8s/jex-adapter.yml.j2` — Deployment/Service, NATS mounts, `configurator` service account.
4. `ansible/roles/services/jex-adapter/defaults/main.yml` — replicas and anti-affinity defaults.
5. `ansible/roles/common/defaults/main.yml` — `source_repos` entry establishing the cyverse-de source repo.
