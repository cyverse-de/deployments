---
type: Service
title: clockwork
description: Scheduler that triggers recurring DE jobs, notably infosquito indexing, publishing over AMQP and reading iRODS.
resource: /ansible/roles/services/clockwork
tags: [clockwork, scheduler, amqp, irods, infosquito]
timestamp: 2026-07-20T00:00:00Z
---

clockwork runs recurring scheduled jobs for the DE. Its config connects it to
[iRODS](/infrastructure/irods.md) (host, zone, admin user, `tree-urls` AVU,
home under `/{{ irods_zone }}/home`) and to
[RabbitMQ](/infrastructure/rabbitmq.md) for publishing events. The one job
configured in the template is search indexing for
[infosquito2](/services/infosquito2.md): `indexing-enabled = True`, queue
basename `infosquito.indexing.1`, with the day of the week controlled by the
`infosquito_daynum` group var.

## Source and image

- Source repo: [cyverse-de/clockwork](https://github.com/cyverse-de/clockwork), cloned as a sibling checkout per `source_repos` in the common role.
- Image: `harbor.cyverse.org/de/clockwork`, pinned by tag and digest in `files/clockwork.json` and hosted on [Harbor](/infrastructure/harbor.md).

## Configuration

The role templates `clockwork.properties.j2` into the `clockwork-configs`
secret, mounted at `/etc/iplant/de`. Notable group vars consumed:
`irods_host`/`irods_zone`/`irods_user`/`irods_password`, the `de_amqp_*`
connection settings, and `infosquito_daynum`.

## Runtime

clockwork is a worker, not an HTTP API: the deployment exposes no port and has
no Kubernetes Service. It picks up `JAVA_TOOL_OPTIONS` (the `low` profile)
from the `java-tool-options` configmap and sends traces to
[Jaeger](/infrastructure/jaeger.md) via the OTEL env vars. Defaults:
`clockwork_replicas: 1`, `clockwork_pod_anti_affinity: true` — a single
scheduler instance is the norm.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags clockwork
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/clockwork/templates/clockwork.properties.j2` — config template: iRODS, AMQP, and infosquito indexing job settings.
2. `ansible/roles/services/clockwork/tasks/main.yml` — creates the `clockwork-configs` secret and includes `deploy-service`.
3. `ansible/roles/services/clockwork/files/clockwork.json` — build descriptor pinning the image.
4. `ansible/roles/services/clockwork/defaults/main.yml` — replica and anti-affinity defaults.
5. `ansible/roles/services/clockwork/templates/k8s/clockwork.yml.j2` — deployment manifest and config mount path.
