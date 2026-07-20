---
type: Service
title: job-status-to-apps-adapter
description: Background worker that forwards recorded job status updates from the DE database to the apps service's job callbacks endpoint.
resource: /ansible/roles/services/job-status-to-apps-adapter
tags: [batch, analyses, job-status, apps, worker]
timestamp: 2026-07-20T00:00:00Z
---

job-status-to-apps-adapter closes the loop of the job-status pipeline: it is a
headless worker (no ports, probes, or Kubernetes Service in its Deployment)
that reads job status updates from the DE database on
[PostgreSQL](/infrastructure/postgresql.md) — where
[job-status-recorder](/services/job-status-recorder.md) stored them — and
delivers them to the [apps](/services/apps.md) service at the configured
callbacks URI (`{{ baseurls_apps }}/callbacks/de-job`). The container runs
with `--batch-size 20`, processing updates in batches. It is also configured
with the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange. Single
replica by default.

- **Source repo:** [cyverse-de/job-status-to-apps-adapter](https://github.com/cyverse-de/job-status-to-apps-adapter)
- **Image:** `harbor.cyverse.org/de/job-status-to-apps-adapter` (pinned in
  `files/job-status-to-apps-adapter.json`)

## Configuration

The role renders the shared job-services template
`templates/jobservices.yml.j2` into the
`job-status-to-apps-adapter-configs` secret, mounted at
`/etc/iplant/de/jobservices.yml`. The operative parts here are `db.uri`,
`apps.callbacks_uri`, and the AMQP URI; the rest of the shared template
(Condor, iRODS, VICE, Keycloak) is common to all job services. Tracing
exports to [Jaeger](/infrastructure/jaeger.md) via OTEL variables from the
`configs` secret. Defaults: `job_status_to_apps_adapter_replicas: 1`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags job-status-to-apps-adapter
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/job-status-to-apps-adapter/files/job-status-to-apps-adapter.json` — image and pinned tag/digest.
2. `ansible/roles/services/job-status-to-apps-adapter/templates/jobservices.yml.j2` — `apps.callbacks_uri`, database, and AMQP configuration.
3. `ansible/roles/services/job-status-to-apps-adapter/templates/k8s/job-status-to-apps-adapter.yml.j2` — headless Deployment and `--batch-size 20` argument.
4. `ansible/roles/services/job-status-to-apps-adapter/defaults/main.yml` — single-replica default.
