---
type: Service
title: job-status-recorder
description: Background worker that consumes job status update messages from AMQP and records them in the DE database.
resource: /ansible/roles/services/job-status-recorder
tags: [batch, analyses, job-status, amqp, worker]
timestamp: 2026-07-20T00:00:00Z
---

job-status-recorder is a headless worker in the batch-analysis pipeline: its
Deployment defines no container ports, probes, or Kubernetes Service. It is
configured with the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange
and the DE database on [PostgreSQL](/infrastructure/postgresql.md), consuming
job status updates from the exchange and writing them to the database, where
[job-status-to-apps-adapter](/services/job-status-to-apps-adapter.md) later
picks them up. It runs a single replica by default.

- **Source repo:** [cyverse-de/job-status-recorder](https://github.com/cyverse-de/job-status-recorder)
- **Image:** `harbor.cyverse.org/de/job-status-recorder` (pinned in
  `files/job-status-recorder.json`)

## Configuration

The role renders the shared job-services template
`templates/jobservices.yml.j2` into the `job-status-recorder-configs` secret,
mounted at `/etc/iplant/de/jobservices.yml`. As with the other job services,
the template carries many sections this worker does not consume (Condor,
iRODS, VICE, Keycloak, service base URLs); the AMQP URI and `db.uri` are the
operative parts. Tracing exports to [Jaeger](/infrastructure/jaeger.md) via
OTEL variables from the `configs` secret. Defaults:
`job_status_recorder_replicas: 1`, with pod anti-affinity enabled when the
replica count is raised.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags job-status-recorder
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/job-status-recorder/files/job-status-recorder.json` — image and pinned tag/digest.
2. `ansible/roles/services/job-status-recorder/templates/jobservices.yml.j2` — AMQP and database configuration.
3. `ansible/roles/services/job-status-recorder/templates/k8s/job-status-recorder.yml.j2` — headless Deployment (no ports, probes, or Service).
4. `ansible/roles/services/job-status-recorder/defaults/main.yml` — single-replica default.
