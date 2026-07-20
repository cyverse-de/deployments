---
type: Service
title: sonora
description: The Discovery Environment web user interface, a Node.js app that fronts terrain and Keycloak.
resource: /ansible/roles/services/sonora
tags: [sonora, ui, frontend, nodejs, keycloak, terrain]
timestamp: 2026-07-20T00:00:00Z
---

Sonora is the DE's web UI. It is a Node.js application (the manifest sets
`NODE_CONFIG_DIR` and serves on port 3000) whose configuration points it at
[terrain](/services/terrain.md) (`baseurls_terrain`) for the backend API,
[Keycloak](/infrastructure/keycloak.md) for login (server URI, realm, client
id/secret), the DE database on
[PostgreSQL](/infrastructure/postgresql.md) (host `groups['dbms'][0]`), and
the `de` exchange on [RabbitMQ](/infrastructure/rabbitmq.md) (`de_amqp_*`
vars). It also carries [iRODS](/infrastructure/irods.md) zone paths, Intercom
and analytics settings, admin group names, tool resource limits, the
[subscriptions](/services/subscriptions.md) checkout URL, and the user portal
base URI.

- **Source repo:** [cyverse-de/sonora](https://github.com/cyverse-de/sonora)
- **Image:** `harbor.cyverse.org/de/sonora` (pinned by digest in the build descriptor)

## Configuration

`templates/sonora.yaml.j2` is rendered into the `sonora-configs` secret and
mounted at `/etc/iplant/de/local.yaml`, which node-config picks up via
`NODE_CONFIG_DIR=./config:/etc/iplant/de`. Deployment shape comes from
`templates/k8s/sonora.yml.j2`: `sonora_replicas` (default 2) with pod
anti-affinity, generous resources (up to 3 CPU / 3Gi), and slow-start probes
(60s initial delay, startup probe with failureThreshold 100).

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags sonora
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/sonora/files/sonora.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/sonora/templates/sonora.yaml.j2` — config template: terrain, Keycloak, DB, AMQP, iRODS, Intercom.
3. `ansible/roles/services/sonora/templates/k8s/sonora.yml.j2` — Deployment/Service manifest, port 3000, NODE_CONFIG_DIR, probes.
4. `ansible/roles/services/sonora/tasks/main.yml` — creates the `sonora-configs` secret and invokes deploy-service.
5. `ansible/roles/services/sonora/defaults/main.yml` — `sonora_replicas`, `sonora_pod_anti_affinity` defaults.
