---
type: Service
title: infosquito2
description: Periodic indexer that reconciles the iRODS ICAT and metadata database into the OpenSearch/Elasticsearch index used by DE search.
resource: /ansible/roles/services/infosquito2
tags: [infosquito2, opensearch, elasticsearch, indexing, irods, amqp]
timestamp: 2026-07-20T00:00:00Z
---

infosquito2 keeps the DE search index in sync with the data store. Its config
connects it to four backends: the iRODS ICAT
[PostgreSQL](/infrastructure/postgresql.md) database
(`icat_user`/`icat_host`, database `ICAT`), the DE `metadata` database
(`metadata_db_name`), the [OpenSearch](/infrastructure/opensearch.md) cluster
(`es_base_uri`/`es_username`/`es_password`, index `es_index`), and two
[RabbitMQ](/infrastructure/rabbitmq.md) brokers — the DE broker's `de` topic
exchange plus the iRODS broker (`irods_amqp_*`), where it publishes work to the
`dewey.indexing` queue consumed by [dewey](/services/dewey.md). The container
runs with `--mode periodic`, so it sweeps on a schedule rather than serving
requests; index sharding is tuned by `infosquito_prefix_length` (default 4).

Source repo: [cyverse-de/infosquito2](https://github.com/cyverse-de/infosquito2);
image `harbor.cyverse.org/de/infosquito2` (`v2026.07.07` pinned by digest) on
[Harbor](/infrastructure/harbor.md).

## Configuration

The role renders `templates/infosquito2.yml.j2` (AMQP, icat, db, irods zone,
infosquito, and elasticsearch sections) into the `infosquito2-configs` Secret,
mounted at `/etc/iplant/de/infosquito2.yml` and passed via `--config`.
`-e load_configs=false` skips regenerating the Secret.

## Deploying

The Deployment runs `infosquito2_replicas` (default 2) pods; limits are more
generous than most workers (4 CPU / 512Mi) since indexing sweeps are
CPU-heavy. OpenTelemetry traces go to [Jaeger](/infrastructure/jaeger.md).
See [Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags infosquito2
```

# Citations

1. `ansible/roles/services/infosquito2/templates/infosquito2.yml.j2` — ICAT/metadata DB URIs, both AMQP URIs, dewey queue, elasticsearch settings.
2. `ansible/roles/services/infosquito2/files/infosquito2.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/infosquito2/templates/k8s/infosquito2.yml.j2` — Deployment: `--mode periodic`, resources, OTEL env.
4. `ansible/roles/services/infosquito2/tasks/main.yml` — creates the `infosquito2-configs` Secret and includes deploy-service.
5. `ansible/roles/services/infosquito2/defaults/main.yml` — `infosquito2_replicas: 2`.
6. `ansible/roles/common/defaults/main.yml` — `es_base_uri`, `es_index`, `infosquito_prefix_length` defaults.
