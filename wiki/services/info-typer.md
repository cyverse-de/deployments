---
type: Service
title: info-typer
description: JVM worker that consumes iRODS change messages from the irods AMQP exchange and stamps files with an ipc-filetype metadata attribute.
resource: /ansible/roles/services/info-typer
tags: [info-typer, irods, amqp, filetype, metadata]
timestamp: 2026-07-20T00:00:00Z
---

info-typer detects file types in the data store. It consumes messages from the
`irods` exchange on the iRODS [RabbitMQ](/infrastructure/rabbitmq.md) broker
(`irods_amqp_*` variables) and connects directly to
[iRODS](/infrastructure/irods.md) (`irods_host`, port 1247, `irods_user`,
home `/{{ irods_zone }}/home`). For each file it reads the first 1024 bytes
(`info-typer.filetype-read-amount`) and records the detected type in the
`ipc-filetype` AVU (`info-typer.type-attribute`). It also publishes events to
the DE broker via `info-typer.events.amqp.uri`. It exposes no ports and no
Kubernetes Service.

Source repo: [cyverse-de/info-typer](https://github.com/cyverse-de/info-typer);
image `harbor.cyverse.org/de/info-typer` (build descriptor currently pins a
`v2026.07.07-dirty` tag by digest) on [Harbor](/infrastructure/harbor.md).

## Configuration

Configuration is a Java-style properties file: the role renders
`templates/info-typer.properties.j2` into the `info-typer-configs` Secret,
mounted at `/etc/iplant/de/info-typer.properties` and passed with `--config`.
`info-typer.environment-name` is set to the namespace (`ns`).
`-e load_configs=false` skips regenerating the Secret.

## Deploying

The Deployment runs `info_typer_replicas` (default 2) JVM pods
(`JAVA_TOOL_OPTIONS` from the `java-tool-options` ConfigMap's `low` profile,
limits 1950m CPU / 2Gi memory) with OpenTelemetry traces exported to
[Jaeger](/infrastructure/jaeger.md). See
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags info-typer
```

# Citations

1. `ansible/roles/services/info-typer/templates/info-typer.properties.j2` — iRODS connection, irods/DE AMQP URIs, type attribute, read amount.
2. `ansible/roles/services/info-typer/files/info-typer.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/info-typer/tasks/main.yml` — creates the `info-typer-configs` Secret and includes deploy-service.
4. `ansible/roles/services/info-typer/templates/k8s/info-typer.yml.j2` — Deployment: replicas, JVM options, resources, OTEL env.
5. `ansible/roles/services/info-typer/defaults/main.yml` — `info_typer_replicas: 2`.
