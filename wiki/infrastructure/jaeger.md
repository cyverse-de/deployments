---
type: Service
title: Jaeger
description: Optional distributed-tracing backend — collector and query deployments backed by Elasticsearch-compatible storage, installed only when the jaeger tag is named explicitly.
resource: /ansible/roles/jaeger
tags: [jaeger, tracing, opentelemetry, observability, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

Jaeger provides distributed tracing for DE services. It is optional and off by default: the
`jaeger` role runs in the final play of `kubernetes.yml` with
`when: "'jaeger' in ansible_run_tags"`, so it installs only when you run the playbook with
`--tags jaeger` explicitly — a plain full run skips it.

## What the role deploys

Everything goes into the `jaeger_namespace` (default `jaeger`):

- `jaeger-collector` — Deployment of `jaegertracing/all-in-one:1.22`
  (`jaeger_collector_replicas`, default 2), exposing gRPC on 14250 and HTTP on 14268 through a
  matching Service.
- `jaeger-query` — Deployment of `jaegertracing/jaeger-query:1.22`
  (`jaeger_query_replicas`, default 2), with a Service on port 16686 for the query UI/API.
- `jaeger-rollover` — a CronJob running `jaegertracing/jaeger-es-rollover` every 30 minutes,
  rolling indexes over at 3 days of age or 500,000,000 documents.

Both deployments use `SPAN_STORAGE_TYPE=elasticsearch` with `ES_SERVER_URLS` set from
`elasticsearch_server_urls` and index prefix set from the environment namespace variable `ns`.
Note that `elasticsearch_server_urls` has no default in `ansible/roles/common/defaults/main.yml`
and is not in the example group_vars — you must define it before running the role, typically
pointing at the cluster's [OpenSearch](/infrastructure/opensearch.md) install. The images are
pinned to the old 1.22 release line.

## How services send traces

Whether services emit traces is controlled separately by `jaeger_enabled` (default `false`).
The `service_configurations` role writes it into the shared `configs` Secret in the DE namespace:
`OTEL_TRACES_EXPORTER` is `jaeger` when enabled and `none` otherwise, alongside
`OTEL_EXPORTER_JAEGER_ENDPOINT` (`jaeger_endpoint`, default
`http://jaeger-collector.jaeger.svc.cluster.local:14250`) and
`OTEL_EXPORTER_JAEGER_HTTP_ENDPOINT` (`jaeger_http_endpoint`, `...:14268/api/traces`).

So enabling tracing is a two-step affair: install the backend with `--tags jaeger`, and set
`jaeger_enabled: true` then re-run service configuration (`--tags configure-services`) so
services pick up the exporter setting.

# Citations

[1] `ansible/roles/jaeger/tasks/main.yml` — collector, query, services, and rollover CronJob definitions.
[2] `ansible/kubernetes.yml` — the `jaeger` tag and its `ansible_run_tags` guard.
[3] `ansible/roles/common/defaults/main.yml` — `jaeger_*` defaults; `elasticsearch_server_urls` absent.
[4] `ansible/roles/service_configurations/tasks/main.yml` — OTEL exporter wiring driven by `jaeger_enabled`.
