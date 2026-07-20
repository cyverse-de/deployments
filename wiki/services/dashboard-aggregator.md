---
type: Service
title: dashboard-aggregator
description: Aggregates the data shown on the DE dashboard — news/event feeds, videos, and app information such as favorites and featured apps.
resource: /ansible/roles/services/dashboard-aggregator
tags: [dashboard, aggregator, feeds, apps, de]
timestamp: 2026-07-20T00:00:00Z
---

dashboard-aggregator backs the Discovery Environment dashboard. Its config
points it at the DE [PostgreSQL](/infrastructure/postgresql.md) database, the
[apps](/services/apps.md), [permissions](/services/permissions.md),
[iplant-groups](/services/iplant-groups.md),
[app-exposer](/services/app-exposer.md), and [metadata](/services/metadata.md)
services (featured apps are found via the `cyverse-blessed` metadata
attribute), plus external RSS feeds — news and events from the website at
`dashboard_aggregator_website_url` (default `https://cyverse.org`) and a
YouTube channel video feed.

- Source: [cyverse-de/dashboard-aggregator](https://github.com/cyverse-de/dashboard-aggregator); image `harbor.cyverse.org/de/dashboard-aggregator` (pinned by digest in the build descriptor), pushed to [Harbor](/infrastructure/harbor.md).
- Config: the role templates `dashboard-aggregator.yaml.j2` into the `dashboard-aggregator-configs` secret, mounted at `/etc/cyverse/de/configs/service.yml`. Notable vars: `dbms_connection_*`, `baseurls_*`, `dashboard_aggregator_website_url`.
- Runtime: 2 replicas by default (`dashboard_aggregator_replicas`) with required pod anti-affinity; listens on port 3000 with `/healthz` liveness/readiness probes; a ClusterIP Service exposes it on port 80.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags
dashboard-aggregator` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/dashboard-aggregator/templates/dashboard-aggregator.yaml.j2` — config: DB, service URLs, website/video feeds.
2. `ansible/roles/services/dashboard-aggregator/files/dashboard-aggregator.json` — pinned image name and digest.
3. `ansible/roles/services/dashboard-aggregator/templates/k8s/dashboard-aggregator.yml.j2` — Deployment/Service, port 3000, probes, anti-affinity.
4. `ansible/roles/services/dashboard-aggregator/tasks/main.yml` — creates the `dashboard-aggregator-configs` secret, then runs deploy-service.
5. `ansible/roles/common/defaults/main.yml` — `dashboard_aggregator_website_url` default and `source_repos` entry.
