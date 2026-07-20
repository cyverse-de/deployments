---
type: Service
title: bulk-typer
description: Assigns file types in bulk by reading files from iRODS and recording the ipc-filetype attribute, driven by AMQP.
resource: /ansible/roles/services/bulk-typer
tags: [bulk-typer, irods, icat, amqp, filetypes]
timestamp: 2026-07-20T00:00:00Z
---

bulk-typer detects and records file types for data store files in bulk. Its
config sets the type attribute (`ipc-filetype`) and how many bytes to read for
detection (`filetype-read-amount = 1024`), and connects the service to
[iRODS](/infrastructure/irods.md) (host, zone, admin user, home under
`/{{ irods_zone }}/home`), directly to the ICAT database (`icat_host`,
`icat_port`, `icat_user`, database `ICAT`), and to
[RabbitMQ](/infrastructure/rabbitmq.md) on the `de` exchange with QoS 1.

## Source and image

- Source repo: [cyverse-de/bulk-typer](https://github.com/cyverse-de/bulk-typer), cloned as a sibling checkout per `source_repos` in the common role.
- Image: `harbor.cyverse.org/de/bulk-typer`, pinned by tag and digest in `files/bulk-typer.json` and hosted on [Harbor](/infrastructure/harbor.md).

## Configuration

The role templates `bulk-typer.properties.j2` into the `bulk-typer-configs`
secret, mounted at `/etc/iplant/de`. Notable group vars consumed:
`irods_host`/`irods_zone`/`irods_user`/`irods_password`, the `icat_*`
variables, and the `de_amqp_*` connection settings. `ns` supplies the
environment name.

## Runtime

bulk-typer is a worker, not an HTTP API: the deployment exposes no port and
has no Kubernetes Service. It runs with `--periodic` alongside `--config`,
picks up `JAVA_TOOL_OPTIONS` (the `high` profile) from the
`java-tool-options` configmap, and sends traces to
[Jaeger](/infrastructure/jaeger.md) via the OTEL env vars. Defaults:
`bulk_typer_replicas: 1`, `bulk_typer_pod_anti_affinity: true`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags bulk-typer
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/bulk-typer/templates/bulk-typer.properties.j2` — config template: iRODS, ICAT, and AMQP settings.
2. `ansible/roles/services/bulk-typer/tasks/main.yml` — creates the `bulk-typer-configs` secret and includes `deploy-service`.
3. `ansible/roles/services/bulk-typer/files/bulk-typer.json` — build descriptor pinning the image.
4. `ansible/roles/services/bulk-typer/defaults/main.yml` — replica and anti-affinity defaults.
5. `ansible/roles/services/bulk-typer/templates/k8s/bulk-typer.yml.j2` — deployment manifest and config mount path.
