---
type: Service
title: subscriptions
description: QMS subscription service that answers subscription requests over NATS and HTTP, backed by the QMS database.
resource: /ansible/roles/services/subscriptions
tags: [subscriptions, qms, nats, quotas, go]
timestamp: 2026-07-20T00:00:00Z
---

The subscriptions service manages QMS subscriptions. Its primary wiring is
through environment variables from the shared `configs` secret:
`QMS_DATABASE_URI` (the QMS database on
[PostgreSQL](/infrastructure/postgresql.md)), `QMS_NATS_CLUSTER` (from
`NATS_URLS`), and `QMS_USERNAME_SUFFIX`. The pod mounts the
`nats-client-tls` and `nats-services-creds` secrets, so it communicates over
[NATS](/infrastructure/nats.md) with the other QMS-related services such as
[qms](/services/qms.md). [sonora](/services/sonora.md) links users to its
checkout URL for plan purchases.

- **Source repo:** [cyverse-de/subscriptions](https://github.com/cyverse-de/subscriptions)
- **Image:** `harbor.cyverse.org/de/subscriptions` (pinned by digest in the build descriptor)

## Configuration

The role renders the shared job-services template
(`templates/jobservices.yml.j2`: AMQP, DE and notifications databases,
service base URLs, iRODS, Keycloak, VICE settings) into the
`subscriptions-configs` secret, mounted at
`/etc/cyverse/de/configs/service.yml`. The Deployment
(`templates/k8s/subscriptions.yml.j2`) runs under the `configurator` service
account with `--log-level=debug`, `subscriptions_replicas` (default 2) and
pod anti-affinity, listening on port 60000 behind a `subscriptions` Service
on port 80.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags subscriptions
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/subscriptions/files/subscriptions.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/subscriptions/templates/k8s/subscriptions.yml.j2` — QMS env vars, NATS TLS/creds mounts, service account.
3. `ansible/roles/services/subscriptions/templates/jobservices.yml.j2` — shared job-services config rendered into the secret.
4. `ansible/roles/services/subscriptions/tasks/main.yml` — creates the `subscriptions-configs` secret and invokes deploy-service.
5. `ansible/roles/services/subscriptions/defaults/main.yml` — `subscriptions_replicas`, `subscriptions_pod_anti_affinity` defaults.
