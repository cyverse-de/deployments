---
type: Service
title: terrain
description: The DE's public API gateway, routing UI requests to the backend services and talking to iRODS and Keycloak directly.
resource: /ansible/roles/services/terrain
tags: [terrain, api-gateway, clojure, keycloak, irods]
timestamp: 2026-07-23T00:00:00Z
---

Terrain is the user-facing API gateway that [sonora](/services/sonora.md)
calls. Its `terrain.properties` config enables per-feature routes and points
each at a backend service: [apps](/services/apps.md),
[analyses](/services/analyses.md), [async-tasks](/services/async-tasks.md),
[metadata](/services/metadata.md), [notifications](/services/notifications.md),
[iplant-groups](/services/iplant-groups.md),
[permissions](/services/permissions.md), [requests](/services/requests.md),
[search](/services/search.md), [data-info](/services/data-info.md),
[user-info](/services/user-info.md) (preferences/sessions/saved searches),
[dashboard-aggregator](/services/dashboard-aggregator.md),
[app-exposer](/services/app-exposer.md) (batch job submission via `/batch`),
[subscriptions](/services/subscriptions.md) (QMS add-ons over HTTP), and
[portal-conductor](/services/portal-conductor.md). It also connects directly
to [iRODS](/infrastructure/irods.md) and the ICAT database,
[Keycloak](/infrastructure/keycloak.md) (including the admin API), the
data-store Elasticsearch index on [OpenSearch](/infrastructure/opensearch.md),
DataCite (permanent ID requests), and the email service for support/tool
requests.

- **Source repo:** [cyverse-de/terrain](https://github.com/cyverse-de/terrain)
- **Image:** `harbor.cyverse.org/de/terrain` (pinned by digest in the build descriptor)

## Configuration

`templates/terrain.properties.j2` (~180 lines) renders into the
`terrain-configs` secret, mounted at `/etc/iplant/de/terrain.properties`.
Notable group vars: the `*_enabled` route flags, `baseurls_*` service URLs,
`irods_*`/`icat_*` credentials, `keycloak_*` and `keycloak_admin_*` settings,
`admin_groups`, `uid_domain`, `jwt_signing_key_password`, `perm_id_datacite_*`,
and `portal_conductor_*`. The Deployment also mounts the `signing-keys` and
`accepted-keys` JWT secrets, and
`templates/k8s/terrain.yml.j2` adds `terrain_replicas` (default 2) and pod
anti-affinity on top of the checked-in `files/k8s/terrain.yml`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags terrain
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/terrain/files/terrain.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/terrain/templates/terrain.properties.j2` — full config: routes, service URLs, iRODS/ICAT, Keycloak, DataCite.
3. `ansible/roles/services/terrain/templates/k8s/terrain.yml.j2` — Deployment with JWT secret mounts, replicas, anti-affinity.
4. `ansible/roles/services/terrain/tasks/main.yml` — creates the `terrain-configs` secret and invokes deploy-service.
5. `ansible/roles/services/terrain/defaults/main.yml` — `terrain_replicas`, `terrain_pod_anti_affinity` defaults.
