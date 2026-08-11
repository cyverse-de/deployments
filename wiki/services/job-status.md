---
type: Service
title: job-status
description: Merged job status pipeline service - HTTP intake, AMQP recording into the DE database, and propagation of updates to the apps service.
resource: /ansible/roles/services/job-status
tags: [batch, analyses, job-status, amqp]
timestamp: 2026-08-06T00:00:00Z
---

job-status combines the three stages of the job status pipeline that used to
be the separate job-status-listener, job-status-recorder, and
job-status-to-apps-adapter services. One deployment now runs three components
in a single process:

- **api** — the HTTP entry point for job status updates on port 60000
  (in-cluster Service `job-status` on port 80, NodePort
  `job_status_nodeport: 31342` created by the networking role, and the `/job`
  ingress route). `POST /{uuid}/status` and `POST /status/batch` publish
  updates to the [RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange
  with the `jobs.updates` routing key. Callers include
  [app-exposer](/services/app-exposer.md) (both its VICE handlers and its
  analysis-expiration worker, formerly timelord),
  [vice-operator](/services/vice-operator.md), the Argo webhook sensor, and
  batch jobs posting from outside the cluster. Other roles point at it via
  `baseurls_job_status`, which the shared job-services config template exposes
  as `vice.job-status.base`.
- **recorder** — consumes `jobs.updates` from the durable
  `job_status_recorder` queue (the queue name is unchanged from the old
  service, so an upgraded deployment inherits the queue and its backlog) and
  inserts each update into the DE database's `job_status_updates` table on
  [PostgreSQL](/infrastructure/postgresql.md).
- **propagator** — polls `job_status_updates` for unpropagated rows, claims
  them with `FOR UPDATE SKIP LOCKED` plus attempt bookkeeping (safe with
  multiple replicas), and POSTs each affected external ID to the
  [apps](/services/apps.md) service's `/callbacks/de-job` endpoint. apps marks
  rows propagated once it processes them; failed rows are retried after a
  backoff.

Liveness and readiness probes hit `/debug/vars`.

- **Source repo:** [cyverse-de/job-status](https://github.com/cyverse-de/job-status)
- **Image:** `harbor.cyverse.org/de/job-status` (pinned in
  `files/job-status.json`)

## Configuration

Unlike the other job services, the role renders a dedicated trimmed template
`templates/job-status.yml.j2` — just the AMQP, DE database, and apps sections
the service actually reads — into the `job-status-configs` secret, mounted at
`/etc/iplant/de/job-status.yml`. The service embeds no OpenTelemetry, so the
manifest carries no OTEL variables. Defaults: `job_status_replicas: 2` with
required pod anti-affinity.

The role also removes the retired job-status-listener/recorder/adapter
Deployments, Service, and config secrets from existing clusters; those cleanup
tasks can be dropped once every deployment has rolled past the merge release.

When cutting an existing cluster over, also redeploy
[app-exposer](/services/app-exposer.md) (plus the `networking`, `ingress`, and
`argo` tags of `kubernetes.yml`): its rendered config embeds
`vice.job-status.base`, which still names the deleted `job-status-listener`
Service until the secret re-renders and the pods restart.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags job-status
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/job-status/templates/job-status.yml.j2` — trimmed service config.
2. `ansible/roles/services/job-status/templates/k8s/job-status.yml.j2` — Deployment/Service and `/debug/vars` probes.
3. `ansible/roles/services/job-status/tasks/main.yml` — config secret and retired-service cleanup.
4. `ansible/roles/common/defaults/main.yml` — `baseurls_job_status`, NodePort 31342, `source_repos` entry.
