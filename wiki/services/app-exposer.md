---
type: Service
title: app-exposer
description: In-cluster API that launches and manages VICE and batch analyses, exposing them via Kubernetes resources.
resource: /ansible/roles/services/app-exposer
tags: [app-exposer, vice, batch, kubernetes, amqp]
timestamp: 2026-07-22T00:00:00Z
---

app-exposer is the DE's job-orchestration API inside the cluster. Its config
wires it to [RabbitMQ](/infrastructure/rabbitmq.md) (exchange `de`, launch/stop
queues), the DE and notifications databases on
[PostgreSQL](/infrastructure/postgresql.md), [iRODS](/infrastructure/irods.md)
(internal and external hosts), [Keycloak](/infrastructure/keycloak.md) (VICE
client), [Harbor](/infrastructure/harbor.md) robot credentials, a
[Condor](/infrastructure/condor.md) section, and DE services:
[apps](/services/apps.md) (job callbacks), [metadata](/services/metadata.md),
[notifications](/services/notifications.md),
[iplant-groups](/services/iplant-groups.md),
[job-status-listener](/services/job-status-listener.md),
[qms](/services/qms.md), [subscriptions](/services/subscriptions.md) (user
overage checks via `GET /users/{username}/overages` before analysis launches),
and iplant-email. app-exposer does not use [NATS](/infrastructure/nats.md).
The config also names the porklock data-transfer image, and its VICE section
covers the gateway provider, base domain, file-transfers image, and the
default backend loading page.

## Source and image

- Source repo: [cyverse-de/app-exposer](https://github.com/cyverse-de/app-exposer).
- Image: `harbor.cyverse.org/de/app-exposer`, pinned in `files/app-exposer.json`.

## Configuration and RBAC

`templates/app-exposer.yml.j2` renders into the `app-exposer-configs` secret,
mounted as `/etc/cyverse/de/configs/service.yml`. Beyond config, the role
creates service accounts (`app-exposer`, `configurator`, `vice-app-runner` in
`vice_ns`), a pod-reader role binding, cluster role bindings granting the
`admin` and `system:persistent-volume-provisioner` cluster roles, and an
`httproute-admin` cluster role for Gateway API HTTPRoutes. Defaults:
`app_exposer_replicas: 2`, `app_exposer_pod_anti_affinity: true`; the container
listens on port 60000.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags app-exposer
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/app-exposer/templates/app-exposer.yml.j2` — config template listing AMQP, DB, iRODS, Keycloak, Harbor, and service URLs.
2. `ansible/roles/services/app-exposer/tasks/main.yml` — service accounts, RBAC, config secret, and deploy-service include.
3. `ansible/roles/services/app-exposer/templates/k8s/app-exposer.yml.j2` — deployment manifest with env wiring and config mounts.
4. `ansible/roles/services/app-exposer/files/app-exposer.json` — build descriptor pinning the image.
5. `ansible/roles/services/app-exposer/defaults/main.yml` — replica and anti-affinity defaults.
