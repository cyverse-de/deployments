---
type: Service
title: subscriptions
description: Subscription service that answers subscription requests over HTTP and serves the merged QMS /v1 API, backed by the QMS database.
resource: /ansible/roles/services/subscriptions
tags: [subscriptions, qms, quotas, go]
timestamp: 2026-08-07T00:00:00Z
---

The subscriptions service manages QMS subscriptions. Its primary wiring is
through environment variables from the shared `configs` secret:
`QMS_DATABASE_URI` (the QMS database on
[PostgreSQL](/infrastructure/postgresql.md)) and `QMS_USERNAME_SUFFIX`. It
serves its whole API over HTTP; [terrain](/services/terrain.md) and
[resource-usage-api](/services/resource-usage-api.md) are its callers.
[sonora](/services/sonora.md) links users to its checkout URL for plan
purchases.

## The merged QMS API

The retired QMS service has been folded into this one. Its `/v1` API is served
alongside the service's own routes from the same process and the same database
connection, unchanged, because terrain parses its `{result, error, status}`
envelope. Terrain reaches it through `terrain.qms.base-uri`, which the terrain
role points at this service — terrain's compiled-in default is `http://qms`, so
that setting is what keeps it working once the QMS Deployment is gone.

The schema migrations for the `qms` database live in this service's repo now,
under `migrations/`, and are what the `setup-databases` pass applies. The
service does not run them itself.

Removing a QMS Deployment left over from before the merge is
`ansible/qms_cleanup.yml`; see
[Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md).

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
2. `ansible/roles/services/subscriptions/templates/k8s/subscriptions.yml.j2` — QMS env vars, config mount, service account.
3. `ansible/roles/services/subscriptions/templates/jobservices.yml.j2` — shared job-services config rendered into the secret.
4. `ansible/roles/services/subscriptions/tasks/main.yml` — creates the `subscriptions-configs` secret and invokes deploy-service.
5. `ansible/roles/services/subscriptions/defaults/main.yml` — `subscriptions_replicas`, `subscriptions_pod_anti_affinity` defaults.
