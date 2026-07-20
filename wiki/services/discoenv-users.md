---
type: Service
title: discoenv-users
description: NATS-based service providing DE user information from the DE database to other discoenv services.
resource: /ansible/roles/services/discoenv-users
tags: [users, nats, de]
timestamp: 2026-07-20T00:00:00Z
---

discoenv-users is the user-lookup member of the NATS-connected "discoenv"
services. The pod mounts the `nats-client-tls` and `nats-services-creds`
secrets for authenticated TLS connections to [NATS](/infrastructure/nats.md)
and reads the cluster URLs from the `DISCOENV_NATS_CLUSTER` env var (sourced
from the `configs` secret). Like
[discoenv-analyses](/services/discoenv-analyses.md) it consumes the shared
job-services config (`jobservices.yml.j2`), which supplies the DE
[PostgreSQL](/infrastructure/postgresql.md) URI, the DE
[RabbitMQ](/infrastructure/rabbitmq.md) exchange, the `uid_domain` used to
qualify usernames, and many other job-services settings only a subset of which
this service uses. Here the rendered file is mounted as
`/etc/cyverse/de/configs/service.yml` rather than the `/etc/iplant/de` path.

- Source: [cyverse-de/discoenv-users](https://github.com/cyverse-de/discoenv-users); image `harbor.cyverse.org/de/discoenv-users`, pinned by digest in the build descriptor and pulled from [Harbor](/infrastructure/harbor.md).
- Config: `jobservices.yml.j2` rendered into the `discoenv-users-configs` secret, mounted at `/etc/cyverse/de/configs/service.yml`.
- Runtime: 2 replicas by default (`discoenv_users_replicas`) with required pod anti-affinity; runs under the `configurator` service account; started with `--log-level debug`. Deployment only — no Kubernetes Service; probes hit `/debug/vars` on port 60000.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags
discoenv-users` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/discoenv-users/templates/jobservices.yml.j2` — the shared job-services config this service consumes.
2. `ansible/roles/services/discoenv-users/files/discoenv-users.json` — pinned image name and digest.
3. `ansible/roles/services/discoenv-users/templates/k8s/discoenv-users.yml.j2` — NATS mounts, `DISCOENV_NATS_CLUSTER`, config mounted as `service.yml`, no Service object.
4. `ansible/roles/services/discoenv-users/tasks/main.yml` — creates the `discoenv-users-configs` secret, then runs deploy-service.
