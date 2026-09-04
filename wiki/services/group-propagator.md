---
type: Service
title: group-propagator
description: AMQP worker that propagates group-membership changes to the data store, using the groups service and data-info.
resource: /ansible/roles/services/group-propagator
tags: [group-propagator, groups, amqp, permissions, irods]
timestamp: 2026-08-04T00:00:00Z
---

group-propagator is a headless worker (no Service, no ports) that listens on
the `de` topic exchange of the DE [RabbitMQ](/infrastructure/rabbitmq.md)
broker and pushes group changes out to the data store. Its config connects it
to the [groups](/services/groups.md) service (as the `de_grouper` user, with
the de-users group named plainly as `de-users` and resolved by type) and to
[data-info](/services/data-info.md), plus the
[iRODS](/infrastructure/irods.md) admin username (`irods_user`) it acts as.

It expands nested groups before writing an iRODS ACL, and does so **by group
ID at every level**. A nested group's member entry carries its own short name,
which is not a lookup key; following it would fail on the first nested group.
Its periodic crawl **paginates**, because the groups service caps one listing
at 1000 and production carries far more — an unpaginated crawl would
propagate the first page and silently skip the rest.

Source repo: [cyverse-de/group-propagator](https://github.com/cyverse-de/group-propagator);
image `harbor.cyverse.org/de/group-propagator` (`v2025.08.05` pinned by digest)
on [Harbor](/infrastructure/harbor.md).

## Configuration

The role renders `templates/group-propagator.yml.j2` — a small, service-specific
YAML config (AMQP URI, groups, data_info, irods sections) — into the
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

1. `ansible/roles/services/group-propagator/templates/group-propagator.yml.j2` — AMQP URI, groups/data-info base URLs, de-users group, iRODS user.
2. `ansible/roles/services/group-propagator/files/group-propagator.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/group-propagator/tasks/main.yml` — creates the `group-propagator-configs` Secret and includes deploy-service.
4. `ansible/roles/services/group-propagator/templates/k8s/group-propagator.yml.j2` — Deployment: replicas, anti-affinity, resources, OTEL env.
5. `ansible/roles/services/group-propagator/defaults/main.yml` — replica count and anti-affinity defaults.
6. `ansible/roles/common/defaults/main.yml` — `baseurls_groups` default (`http://groups`).
