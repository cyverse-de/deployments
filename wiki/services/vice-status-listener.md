---
type: Service
title: vice-status-listener
description: Namespace-scoped worker that watches VICE analyses in Kubernetes and reports their status changes.
resource: /ansible/roles/services/vice-status-listener
tags: [vice, status, kubernetes-watch, jobservices, go]
timestamp: 2026-07-20T00:00:00Z
---

The vice-status-listener watches the cluster for VICE analysis status
changes: it runs under the `app-exposer` service account (Kubernetes API
access), is started with `--namespace $(VSL_NAMESPACE)` where the namespace
is injected from the pod's own metadata, and sets `CLUSTER=1`. Its shared
job-services configuration gives it the `de` exchange on
[RabbitMQ](/infrastructure/rabbitmq.md), the DE database on
[PostgreSQL](/infrastructure/postgresql.md), and the
[job-status-listener](/services/job-status-listener.md) base URL, which is
how analysis status updates flow into the rest of the DE.

- **Source repo:** [cyverse-de/vice-status-listener](https://github.com/cyverse-de/vice-status-listener)
- **Image:** `harbor.cyverse.org/de/vice-status-listener` (pinned by digest in the build descriptor)

## Configuration

The role renders the shared job-services template
(`templates/jobservices.yml.j2`, identical to the user-info/timelord copy)
into the `vice-status-listener-configs` secret, mounted at
`/etc/iplant/de/jobservices.yml`. The Deployment
(`templates/k8s/vice-status-listener.yml.j2`) is a pure background worker:
it declares no ports, probes, or Service. Defaults:
`vice_status_listener_replicas: 1` with pod anti-affinity enabled.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags vice-status-listener
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) and
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md).

# Citations

1. `ansible/roles/services/vice-status-listener/files/vice-status-listener.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/vice-status-listener/templates/k8s/vice-status-listener.yml.j2` — worker Deployment: namespace arg, service account, no Service.
3. `ansible/roles/services/vice-status-listener/templates/jobservices.yml.j2` — shared job-services config with AMQP, DB, and job-status settings.
4. `ansible/roles/services/vice-status-listener/tasks/main.yml` — creates the `vice-status-listener-configs` secret and invokes deploy-service.
5. `ansible/roles/services/vice-status-listener/defaults/main.yml` — `vice_status_listener_replicas`, anti-affinity defaults.
