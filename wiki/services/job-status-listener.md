---
type: Service
title: job-status-listener
description: HTTP endpoint that receives job status updates from running analyses and feeds them into the job-services pipeline.
resource: /ansible/roles/services/job-status-listener
tags: [batch, analyses, job-status, amqp, jobservices]
timestamp: 2026-07-20T00:00:00Z
---

job-status-listener is the entry point for job status updates: it listens on
HTTP port 60000 (in-cluster Service `job-status-listener` on port 80, with a
NodePort `job_status_listener_nodeport: 31342` reserved in the common role so
updates can also arrive from outside the cluster). Other roles point at it via
`baseurls_job_status_listener` — for example the VICE section of the shared
job-services config sets `vice.job-status.base` to this service. It is
configured with the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange
and the DE database on [PostgreSQL](/infrastructure/postgresql.md). Liveness
and readiness probes hit `/debug/vars`.

- **Source repo:** [cyverse-de/job-status-listener](https://github.com/cyverse-de/job-status-listener)
- **Image:** `harbor.cyverse.org/de/job-status-listener` (pinned in
  `files/job-status-listener.json`)

## Configuration

The role renders the shared job-services template
`templates/jobservices.yml.j2` into the `job-status-listener-configs` secret,
mounted at `/etc/iplant/de/jobservices.yml`. The template is common to the job
services and carries more sections than any one of them uses (AMQP, databases,
[Condor](/infrastructure/condor.md), [iRODS](/infrastructure/irods.md), VICE,
service base URLs). Tracing exports to [Jaeger](/infrastructure/jaeger.md) via
OTEL variables from the `configs` secret. Defaults:
`job_status_listener_replicas: 2` with required pod anti-affinity.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags job-status-listener
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/job-status-listener/files/job-status-listener.json` — image and pinned tag/digest.
2. `ansible/roles/services/job-status-listener/templates/jobservices.yml.j2` — shared job-services config.
3. `ansible/roles/services/job-status-listener/templates/k8s/job-status-listener.yml.j2` — Deployment/Service and `/debug/vars` probes.
4. `ansible/roles/common/defaults/main.yml` — `baseurls_job_status_listener`, NodePort 31342, `source_repos` entry.
