---
type: Service
title: formation
description: Keycloak-authenticated HTTP API (with MCP support) fronting apps, app-exposer, and permissions for launching and managing analyses, including VICE URL readiness checks.
resource: /ansible/roles/services/formation
tags: [formation, mcp, keycloak, vice, api]
timestamp: 2026-07-20T00:00:00Z
---

formation is an HTTP API listening on port 8000 (exposed in-cluster as Service
`formation` on port 80). Its config wires it to
[Keycloak](/infrastructure/keycloak.md) (server URI, realm, client ID/secret,
plus a dedicated `formation_mcp_client_id`, default `mcp-client`) and to three
DE services: [apps](/services/apps.md), [app-exposer](/services/app-exposer.md),
and [permissions](/services/permissions.md). It also carries
[iRODS](/infrastructure/irods.md) credentials and VICE settings — `vice_domain`
and URL-check timeout/retry/cache tuning — so it can verify when a VICE
analysis URL becomes reachable. MCP support is toggled by
`formation_mcp_enabled` (default `"true"`), and the public URL is
`formation_base_url` (default `https://{{ de_hostname }}/formation`).

Source repo: [cyverse-de/formation](https://github.com/cyverse-de/formation);
image `harbor.cyverse.org/de/formation` (`v2026.07.07` pinned by digest) on
[Harbor](/infrastructure/harbor.md).

## Configuration

Unusually for a DE service, the config is JSON: the role renders
`templates/formation.json.j2` into the `formation-configs` Secret, mounted at
`/etc/cyverse/formation/formation.json` and located via the `CONFIG_FILE`
environment variable. User identities get the `@{{ uid_domain }}` suffix.
`-e load_configs=false` skips regenerating the Secret.

## Deploying

The Deployment runs `formation_replicas` (default 2) pods with required pod
anti-affinity (`formation_pod_anti_affinity`, default true) and HTTP
liveness/readiness probes on `/`. See
[Building and Deploying Services](/playbooks/build-and-deploy.md):

```bash
ansible-playbook -i $INVENTORY deploy_it.yml --tags formation
```

# Citations

1. `ansible/roles/services/formation/templates/formation.json.j2` — Keycloak, iRODS, service URLs, VICE and MCP application settings.
2. `ansible/roles/services/formation/files/formation.json` — build descriptor with image name and pinned tag/digest.
3. `ansible/roles/services/formation/templates/k8s/formation.yml.j2` — Deployment and Service: port 8000, probes, anti-affinity, `CONFIG_FILE`.
4. `ansible/roles/services/formation/tasks/main.yml` — creates the `formation-configs` Secret and includes deploy-service.
5. `ansible/roles/services/formation/defaults/main.yml` — replica count and anti-affinity defaults.
6. `ansible/roles/common/defaults/main.yml` — `formation_mcp_enabled`, `formation_base_url`, `formation_mcp_client_id` defaults.
