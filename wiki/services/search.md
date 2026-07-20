---
type: Service
title: search
description: Search API that queries the data-store Elasticsearch/OpenSearch index and consults data-info for path information.
resource: /ansible/roles/services/search
tags: [search, opensearch, elasticsearch, data-info, go]
timestamp: 2026-07-20T00:00:00Z
---

The search service provides the DE's search API. Its configuration is small:
an `elasticsearch` block (base URI, username, password, and index from the
`es_*` group vars) and a `data_info` base URL — so it answers search queries
against the data-store index served by [OpenSearch](/infrastructure/opensearch.md)
and calls [data-info](/services/data-info.md) for path details.
[terrain](/services/terrain.md) routes `/search` requests to it via
`baseurls_search`.

- **Source repo:** [cyverse-de/search](https://github.com/cyverse-de/search)
- **Image:** `harbor.cyverse.org/de/search` (pinned by digest in the build descriptor)

## Configuration

The role renders `templates/search.yaml.j2` into the `search-configs` secret,
mounted at `/etc/iplant/de/search.yaml` and passed via `--config`. Notable
group vars: `es_base_uri`, `es_username`, `es_password`, `es_index`, and
`baseurls_data_info`. Deployment shape comes from
`templates/k8s/search.yml.j2`: `search_replicas` (default 2) and
`search_pod_anti_affinity` (default true), listening on port 60000 behind a
`search` Service on port 80, with liveness on `/debug/vars` and readiness on
`/ready`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags search
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) for the
build side (`build_it.yml --tags search` uses `files/skaffold.yaml`).

# Citations

1. `ansible/roles/services/search/files/search.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/search/templates/search.yaml.j2` — config template: Elasticsearch and data-info settings.
3. `ansible/roles/services/search/templates/k8s/search.yml.j2` — Deployment/Service manifest, ports, probes, replicas.
4. `ansible/roles/services/search/tasks/main.yml` — creates the `search-configs` secret and invokes deploy-service.
5. `ansible/roles/services/search/defaults/main.yml` — `search_replicas`, `search_pod_anti_affinity` defaults.
