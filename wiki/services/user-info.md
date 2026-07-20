---
type: Service
title: user-info
description: HTTP service backing user preferences, sessions, and saved searches, stored in the DE database.
resource: /ansible/roles/services/user-info
tags: [user-info, preferences, sessions, saved-searches, go]
timestamp: 2026-07-20T00:00:00Z
---

The user-info service serves per-user state: [terrain](/services/terrain.md)
points its preferences, sessions, and saved-searches endpoints at
`{{ baseurls_user_info }}/preferences`, `/sessions`, and `/searches`. It is
configured with the shared job-services config, whose relevant pieces for
this service are the DE and notifications database URIs on
[PostgreSQL](/infrastructure/postgresql.md) and the `de` exchange on
[RabbitMQ](/infrastructure/rabbitmq.md).

- **Source repo:** [cyverse-de/user-info](https://github.com/cyverse-de/user-info)
- **Image:** `harbor.cyverse.org/de/user-info` (pinned by digest in the build descriptor)

## Configuration

The role renders the shared job-services template
(`templates/jobservices.yml.j2`) into the `user-info-configs` secret, mounted
at `/etc/iplant/de/jobservices.yml` and passed via `--config`. Notable group
vars: `dbms_connection_*`, `de_db_name`, `notifications_db_name`, and
`de_amqp_*`. The Deployment (`templates/k8s/user-info.yml.j2`) runs
`user_info_replicas` (default 2) with pod anti-affinity, listening on port
60000 behind a `user-info` Service on port 80 with `/` as the health check.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags user-info
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/user-info/files/user-info.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/user-info/templates/jobservices.yml.j2` — shared job-services config with DB and AMQP settings.
3. `ansible/roles/services/user-info/templates/k8s/user-info.yml.j2` — Deployment/Service manifest, ports, probes, replicas.
4. `ansible/roles/services/user-info/tasks/main.yml` — creates the `user-info-configs` secret and invokes deploy-service.
5. `ansible/roles/services/terrain/templates/terrain.properties.j2` — terrain routes preferences/sessions/saved searches to this service.
