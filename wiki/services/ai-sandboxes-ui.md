---
type: Service
title: ai-sandboxes-ui
description: AI Discovery Lab web UI, a Next.js app that authenticates via Keycloak and proxies API calls to terrain.
resource: /ansible/roles/services/ai-sandboxes-ui
tags: [ai-sandboxes-ui, ui, frontend, nodejs, nextjs, keycloak, terrain, ai-discovery-lab]
timestamp: 2026-10-01T00:00:00Z
---

The AI Discovery Lab UI (ai-sandboxes-ui) is an alternate web interface to the
DE backend services. It is a Next.js application configured entirely through
environment variables: [terrain](/services/terrain.md) for the API
(`AI2S_TERRAIN_BASE_URL`), [Keycloak](/infrastructure/keycloak.md) for
authentication (`AI2S_KEYCLOAK_ISSUER`, client ID/secret), and NextAuth for
session management (`NEXTAUTH_URL`, `NEXTAUTH_SECRET`).

- **Source repo:** cyverse-de/ai-sandboxes-ui
- **Image:** `harbor.cyverse.org/de/ai-sandboxes-ui`

## Configuration

Environment variables are stored in the `ai-sandboxes-ui-configs` Secret
(created by `tasks/main.yml` using `stringData`). The Deployment shape comes
from `templates/k8s/ai-sandboxes-ui.yml.j2`: `ai_sandboxes_ui_replicas`
(default 1) with pod anti-affinity, resources up to 3 CPU / 3Gi, and
slow-start probes (60s initial delay, startup probe with failureThreshold 100).

Key variables (defaults in `roles/common/defaults/main.yml`):

- `ai2s_terrain_base_url` — defaults to the in-cluster terrain URL
- `ai2s_keycloak_issuer` — derived from `keycloak_server_uri` and `keycloak_realm_name`
- `ai2s_keycloak_client_id` — default `ai-sandboxes`
- `ai2s_keycloak_client_secret` — must be set
- `ai2s_admin_groups` — must be set
- `ai2s_nextauth_url` — must be set (the public URL of the app)
- `ai2s_nextauth_secret` — must be set (generate with `openssl rand -base64 32`)
- `ai2s_log_level` — default `info`

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags ai-sandboxes-ui
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

[1] `ansible/roles/services/ai-sandboxes-ui/tasks/main.yml` — creates the `ai-sandboxes-ui-configs` secret and invokes deploy-service.
[2] `ansible/roles/services/ai-sandboxes-ui/templates/k8s/ai-sandboxes-ui.yml.j2` — Deployment/Service manifest, port 3000, env-var config, probes.
[3] `ansible/roles/services/ai-sandboxes-ui/defaults/main.yml` — `ai_sandboxes_ui_replicas`, `ai_sandboxes_ui_pod_anti_affinity` defaults.
[4] `ansible/roles/common/defaults/main.yml` — `ai2s_*` variable defaults.
