---
type: Service
title: group-propagator
description: AMQP worker that propagates Grouper group-membership changes to the data store, using iplant-groups and data-info.
resource: /ansible/roles/services/group-propagator
tags: [group-propagator, grouper, amqp, permissions, irods]
timestamp: 2026-07-20T00:00:00Z
---

group-propagator is a headless worker (no Service, no ports) that listens on
the `de` topic exchange of the DE [RabbitMQ](/infrastructure/rabbitmq.md)
broker and pushes group changes out to the data store. Its config connects it
to [iplant-groups](/services/iplant-groups.md) (as the `de_grouper` user, with
the [Grouper](/infrastructure/grouper.md) folder prefix
`grouper_folder_name_prefix` and the environment's public group
`iplant:de:{{ ns }}:users:de-users`) and to
[data-info](/services/data-info.md), plus the
[iRODS](/infrastructure/irods.md) admin username (`irods_user`) it acts as.

Source repo: [cyverse-de/group-propagator](https://github.com/cyverse-de/group-propagator);
image `harbor.cyverse.org/de/group-propagator` (`v2025.08.05` pinned by digest)
on [Harbor](/infrastructure/harbor.md).

## Configuration

The role renders `templates/group-propagator.yml.j2` — a small, service-specific
YAML config (AMQP URI, iplant_groups, data_info, irods sections) — into the
`group-propagator-configs` Secret, mounted at
`/etc/iplant/de/group-propagator.yml`. `-e load_configs=false` skips
regenerating it.

## Deploying

The Deployment runs `group_propagator_replicas` (default 2) small pods
(100m CPU / 256Mi limits) with required pod anti-affinity
(`group_propagator_pod_anti_affinity`, default true) and OpenTelemetry traces
exported to [Jaeger](/infrastructure/jaeger.md). See
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags group-propagator
```

# Citations

1. `ansible/roles/services/group-propagator/templates/group-propagator.yml.j2` — AMQP URI, iplant-groups/data-info base URLs, public group, iRODS user.
2. `ansible/roles/services/group-propagator/files/group-propagator.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/group-propagator/tasks/main.yml` — creates the `group-propagator-configs` Secret and includes deploy-service.
4. `ansible/roles/services/group-propagator/templates/k8s/group-propagator.yml.j2` — Deployment: replicas, anti-affinity, resources, OTEL env.
5. `ansible/roles/services/group-propagator/defaults/main.yml` — replica count and anti-affinity defaults.
6. `ansible/roles/common/defaults/main.yml` — `grouper_folder_name_prefix` default (`iplant:de:{{ env }}`).
