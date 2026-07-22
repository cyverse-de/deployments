---
type: Service
title: discoenv-analyses
description: NATS-based service providing analysis (job) information from the DE database to other discoenv services.
resource: /ansible/roles/services/discoenv-analyses
tags: [analyses, jobs, nats, de]
timestamp: 2026-07-22T00:00:00Z
---

discoenv-analyses is one of the NATS-connected "discoenv" services: its pod
mounts the `nats-client-tls` and `nats-services-creds` secrets so it can talk
to [NATS](/infrastructure/nats.md) with TLS and credentials. Rather than a
dedicated config, it consumes the shared job-services config
(`jobservices.yml.j2`), which carries the DE and
notifications [PostgreSQL](/infrastructure/postgresql.md) URIs, the DE
[RabbitMQ](/infrastructure/rabbitmq.md) `de` topic exchange, and settings for
[apps](/services/apps.md), [metadata](/services/metadata.md),
[notifications](/services/notifications.md), [qms](/services/qms.md),
[iplant-groups](/services/iplant-groups.md),
[Condor](/infrastructure/condor.md), [iRODS](/infrastructure/irods.md),
[Keycloak](/infrastructure/keycloak.md), [Harbor](/infrastructure/harbor.md),
and VICE — only a subset of which any one consumer uses.

- Source: [cyverse-de/discoenv-analyses](https://github.com/cyverse-de/discoenv-analyses); image `harbor.cyverse.org/de/discoenv-analyses`, pinned by digest in the build descriptor.
- Config: the role renders `jobservices.yml.j2` into the `discoenv-analyses-configs` secret, mounted at `/etc/iplant/de/jobservices.yml`.
- Runtime: 2 replicas by default (`discoenv_analyses_replicas`) with required pod anti-affinity. The manifest defines a Deployment only — no Kubernetes Service; health probes hit the Go expvar endpoint `/debug/vars` on port 60000.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags
discoenv-analyses` — see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/discoenv-analyses/templates/jobservices.yml.j2` — the shared job-services config this service consumes.
2. `ansible/roles/services/discoenv-analyses/files/discoenv-analyses.json` — pinned image name and digest.
3. `ansible/roles/services/discoenv-analyses/templates/k8s/discoenv-analyses.yml.j2` — NATS TLS/creds mounts, `/debug/vars` probes, no Service object.
4. `ansible/roles/services/discoenv-analyses/tasks/main.yml` — creates the `discoenv-analyses-configs` secret, then runs deploy-service.
