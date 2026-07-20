---
type: Service
title: OpenSearch
description: The single-node in-cluster OpenSearch StatefulSet backing the DE data-search pipeline, deployed by the opensearch role via kubernetes.yml or the standalone opensearch.yml playbook.
resource: /ansible/roles/opensearch
tags: [opensearch, search, statefulset, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

OpenSearch is the search index behind the DE data-search pipeline — consumed by
[dewey](/services/dewey.md), [infosquito2](/services/infosquito2.md),
[search](/services/search.md), and [terrain](/services/terrain.md). The `opensearch` role
deploys a single-node instance in the DE namespace (`ns`) so the deployment is
self-contained. It is on by default (`opensearch_enabled: true`); set it to `false` to use
an external cluster instead and point `es_base_uri` at it.

## Installation

The role runs in `kubernetes.yml` under the `opensearch` tag, and also has a small
standalone playbook:

```bash
ansible-playbook -i <inventory> --tags opensearch kubernetes.yml
# or
ansible-playbook -i <inventory> opensearch.yml
```

Both render `k8s/opensearch.yml.j2` into a StatefulSet plus a `opensearch` Service
(ports 9200 http, 9300 transport).

## Notable configuration

- Runs `{{ opensearch_image }}:{{ opensearch_version }}` (default
  `opensearchproject/opensearch:2.19.1`) with `discovery.type: single-node` and
  `opensearch_replicas: 1`.
- A privileged busybox init container runs `sysctl -w vm.max_map_count=262144`, keeping the
  kernel requirement local to the pod instead of relying on a node-level sysctl.
- The security plugin is disabled (`DISABLE_SECURITY_PLUGIN=true`) — the node is
  internal-only. DE consumers still send basic-auth headers, which OpenSearch ignores.
- JVM heap is fixed at `opensearch_heap_size` (default 1g); keep it at roughly half of
  `opensearch_mem_limit` (default 4Gi) so the rest is available for the OS page cache and
  off-heap Lucene structures.
- Data lives on a `volumeClaimTemplates` PVC: `opensearch_storage_size` (20Gi) on
  `opensearch_storage_class` (default `longhorn` — see
  [Longhorn](/infrastructure/longhorn.md)).
- Readiness waits for cluster health `yellow` (normal for a single node); a startup probe
  allows up to 30 failures before liveness kicks in.

# Citations

[1] `ansible/roles/opensearch/defaults/main.yml` — enable flag, image/version, heap, storage, and resource defaults.
[2] `ansible/roles/opensearch/tasks/main.yml` — namespace creation and template application.
[3] `ansible/roles/opensearch/templates/k8s/opensearch.yml.j2` — StatefulSet, init container, env, probes, and Service.
[4] `ansible/opensearch.yml` — the standalone deployment playbook.
[5] `ansible/kubernetes.yml` — the `opensearch` tag.
