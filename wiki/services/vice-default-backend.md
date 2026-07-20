---
type: Service
title: vice-default-backend
description: Fallback backend for VICE wildcard traffic that serves a loading page or 302-redirects unrecognized subdomains to the owning cluster.
resource: /ansible/roles/services/vice-default-backend
tags: [vice, default-backend, gateway, redirect, go]
timestamp: 2026-07-20T00:00:00Z
---

The vice-default-backend receives VICE requests whose subdomain doesn't match
a running analysis on this cluster (the wildcard HTTPRoute's default target).
Configured entirely by environment variables — there is no config template —
it takes `VICE_DOMAIN` from the shared `configs` secret
(`VICE_BASE_DOMAIN`) and `APP_EXPOSER_URL=http://app-exposer`. Per the
comment in the manifest, those two together enable cross-cluster redirects:
the backend asks [app-exposer](/services/app-exposer.md) which operator owns
the subdomain and 302s the browser to that operator's base URL. Both must be
set together, or both omitted to disable the lookup.

- **Source repo:** [cyverse-de/vice-default-backend](https://github.com/cyverse-de/vice-default-backend)
- **Image:** `harbor.cyverse.org/de/vice-default-backend` (pinned by digest in the build descriptor)

## Configuration

Unusually for a DE service, `tasks/main.yml` creates no config secret — it
only invokes deploy-service. The Deployment
(`templates/k8s/vice-default-backend.yml.j2`) runs
`vice_default_backend_replicas` (default 2) with pod anti-affinity, listens
on port 60000 behind a `vice-default-backend` Service on port 80, and health
checks `/healthz`. Optional `LOOKUP_TIMEOUT` and `LOOKUP_CACHE_TTL` env vars
exist in the source but are not set here.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags vice-default-backend
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md), and
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md) for the routing
context.

# Citations

1. `ansible/roles/services/vice-default-backend/files/vice-default-backend.json` — build descriptor with image name and pinned digest.
2. `ansible/roles/services/vice-default-backend/templates/k8s/vice-default-backend.yml.j2` — env-only configuration and the cross-cluster redirect comment.
3. `ansible/roles/services/vice-default-backend/tasks/main.yml` — deploy-service invocation with no config secret.
4. `ansible/roles/services/vice-default-backend/defaults/main.yml` — `vice_default_backend_replicas`, `vice_default_backend_pod_anti_affinity` defaults.
