---
type: Service
title: vice-operator
description: Operator that runs VICE analyses in a dedicated namespace, built from the app-exposer repo and deployed with its own RBAC instead of skaffold.
resource: /ansible/roles/services/vice-operator
tags: [vice, operator, app-exposer, rbac, gateway, gpu]
timestamp: 2026-07-20T00:00:00Z
---

The vice-operator manages VICE analyses inside the `vice_ns` namespace: its
Role grants full control of pods, services, configmaps, secrets, PVCs,
deployments, network policies, Gateway API `gateways`/`httproutes`, and
Traefik middlewares, and a ClusterRole covers persistent volumes and nodes.
Its flags wire in [Keycloak](/infrastructure/keycloak.md) auth for the VICE
proxy and API, the gateway provider, the porklock and vice-proxy images,
[GPU](/infrastructure/gpu-workers.md) vendor/model mappings, the image
registry credentials, the iRODS CSI driver toggle, and a
`--status-listener-url` pointing at `https://<de_hostname>/job`.

This role is unusual in two ways. First, the binary is built from the
[cyverse-de/app-exposer](https://github.com/cyverse-de/app-exposer) repo
(`tasks/build.yml` sets `source_service: app-exposer`; the image is
`harbor.cyverse.org/de/app-exposer`, run with `command: /vice-operator`).
Second, there is no skaffold config or config-file template: `tasks/main.yml`
creates the namespace, service account, RBAC, and the `vice-operator-secret`
(admin entitlements, registry password, Keycloak/Swagger client secrets,
state HMAC secret) directly with `kubernetes.core.k8s`, then applies the
rendered `templates/vice_operator.yml.j2` Deployment.

## Configuration

Everything is CLI flags and secrets rendered from `vice_operator_*` group
vars, plus `image_cache_mode` (`daemonset`, `cron`, or `manual-mirror` — the
latter mounts `files/repos.json` as a ConfigMap; see
[VICE Image Cache](/playbooks/vice-image-cache.md)). Default
`vice_operator_replicas` is 1.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags vice-operator
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) and
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md).

# Citations

1. `ansible/roles/services/vice-operator/files/vice-operator.json` — build descriptor: the app-exposer image, pinned by digest.
2. `ansible/roles/services/vice-operator/tasks/build.yml` — builds from the app-exposer source repo via `source_service`.
3. `ansible/roles/services/vice-operator/tasks/main.yml` — namespace, service account, Role/ClusterRole, and direct k8s deploy.
4. `ansible/roles/services/vice-operator/templates/vice_operator.yml.j2` — secret, optional repos ConfigMap, and the flag-driven Deployment.
5. `ansible/roles/services/vice-operator/files/repos.json` — image mirror list for `manual-mirror` cache mode.
