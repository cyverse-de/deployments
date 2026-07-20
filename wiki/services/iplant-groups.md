---
type: Service
title: iplant-groups
description: HTTP facade over the Grouper Web Services API that the rest of the DE uses for group and subject management.
resource: /ansible/roles/services/iplant-groups
tags: [iplant-groups, grouper, groups, amqp, api]
timestamp: 2026-07-20T00:00:00Z
---

iplant-groups is the DE's front end to [Grouper](/infrastructure/grouper.md).
Its config points at the Grouper Web Services endpoint
(`baseurls_grouper_web_services`, default `http://grouper-ws/grouper-ws`, API
version `v2_2_000`) with the `grouper_connection_user`/`grouper_connection_pass`
credentials, and at the `de` exchange on the DE
[RabbitMQ](/infrastructure/rabbitmq.md) broker. Other services reach it at
`baseurls_iplant_groups` (default `http://iplant-groups`) — consumers include
[group-propagator](/services/group-propagator.md) and the jobservices workers,
which call it as the `de_grouper` user.

Source repo: [cyverse-de/iplant-groups](https://github.com/cyverse-de/iplant-groups);
image `harbor.cyverse.org/de/iplant-groups` (`v2025.08.05` pinned by digest) on
[Harbor](/infrastructure/harbor.md).

## Configuration

The role renders `templates/iplant-groups.properties.j2` — a short properties
file with just the Grouper and AMQP settings — into the
`iplant-groups-configs` Secret, mounted at
`/etc/iplant/de/iplant-groups.properties` and passed with `--config`. The pod
also mounts the `gpg-keys` Secret at `/etc/iplant/crypto`.
`-e load_configs=false` skips regenerating the config Secret.

## Deploying

The Deployment runs `iplant_groups_replicas` (default 2) JVM pods
(`JAVA_TOOL_OPTIONS` `low` profile, limits 3 CPU / 2Gi) with required pod
anti-affinity, slow-start probes on port 60000 (60s initial delay plus a
startup probe), and a Service on port 80. OpenTelemetry traces go to
[Jaeger](/infrastructure/jaeger.md). See
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags iplant-groups
```

# Citations

1. `ansible/roles/services/iplant-groups/templates/iplant-groups.properties.j2` — Grouper WS base URL/credentials/API version, DE AMQP URI.
2. `ansible/roles/services/iplant-groups/files/iplant-groups.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/iplant-groups/templates/k8s/iplant-groups.yml.j2` — Deployment/Service: probes, anti-affinity, gpg-keys mount, JVM options.
4. `ansible/roles/services/iplant-groups/tasks/main.yml` — creates the `iplant-groups-configs` Secret and includes deploy-service.
5. `ansible/roles/services/iplant-groups/defaults/main.yml` — replica count and anti-affinity defaults.
6. `ansible/roles/common/defaults/main.yml` — `baseurls_grouper_web_services` and `baseurls_iplant_groups` defaults.
