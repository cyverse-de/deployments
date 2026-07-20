---
type: Service
title: timelord
description: Background worker that tracks VICE analysis time limits, using the shared job-services configuration and Kubernetes API access.
resource: /ansible/roles/services/timelord
tags: [timelord, vice, time-limits, jobservices, go]
timestamp: 2026-07-20T00:00:00Z
---

Timelord is a job-services worker concerned with analysis time limits: its
config carries the VICE settings (including `vice.time-limit-extension`), it
runs under the `app-exposer` service account (so it can use the Kubernetes
API like [app-exposer](/services/app-exposer.md) does), and sets `CLUSTER=1`.
Per its configuration it reaches the DE and notifications databases on
[PostgreSQL](/infrastructure/postgresql.md), the `de` exchange on
[RabbitMQ](/infrastructure/rabbitmq.md), and the
[apps](/services/apps.md), [notifications](/services/notifications.md), and
iplant-email service URLs — the pieces needed to find expiring analyses and
notify their owners.

- **Source repo:** [cyverse-de/timelord](https://github.com/cyverse-de/timelord)
- **Image:** `harbor.cyverse.org/de/timelord` (pinned by digest in the build descriptor)

## Configuration

The role renders the shared job-services template
(`templates/jobservices.yml.j2`) into the `timelord-configs` secret, mounted
at `/etc/iplant/de/jobservices.yml`. Notable group vars: `de_amqp_*`,
`dbms_connection_*`, `de_db_name`, `notifications_db_name`, `baseurls_*`,
and the `vice_*` settings. The Deployment
(`templates/k8s/timelord.yml.j2`) runs `timelord_replicas` (default 2) with
pod anti-affinity, listens on port 60000 behind a `timelord` Service on port
80, and probes `/debug/vars`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags timelord
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/timelord/files/timelord.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/timelord/templates/jobservices.yml.j2` — shared job-services config with the VICE time-limit settings.
3. `ansible/roles/services/timelord/templates/k8s/timelord.yml.j2` — Deployment with `app-exposer` service account, `CLUSTER=1`, probes.
4. `ansible/roles/services/timelord/tasks/main.yml` — creates the `timelord-configs` secret and invokes deploy-service.
5. `ansible/roles/services/timelord/defaults/main.yml` — `timelord_replicas`, `timelord_pod_anti_affinity` defaults.
