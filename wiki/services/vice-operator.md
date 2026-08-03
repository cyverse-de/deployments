---
type: Service
title: vice-operator
description: Operator that runs VICE analyses in a dedicated namespace, built from the app-exposer repo and deployed with its own RBAC instead of skaffold.
resource: /ansible/roles/services/vice-operator
tags: [vice, operator, app-exposer, rbac, gateway, gpu]
timestamp: 2026-08-03T00:00:00Z
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
creates the namespace, service account, RBAC, the `vice-operator-secret`
(admin entitlements, registry password, Keycloak/Swagger client secrets,
state HMAC secret), and the `porklock-config` Secret (iRODS credentials for
porklock file transfers when `mount_data_store=false`) directly with
`kubernetes.core.k8s`, then applies the rendered `templates/vice_operator.yml.j2`
Deployment.

## Configuration

Everything is CLI flags and secrets rendered from `vice_operator_*` group
vars, plus `image_cache_mode` (`daemonset`, `cron`, or `manual-mirror` — the
latter mounts `files/repos.json` as a ConfigMap; see
[VICE Image Cache](/playbooks/vice-image-cache.md)). Default
`vice_operator_replicas` is 1.

`vice_operator_ca_bundle_configmap` does double duty. It mounts the named
ConfigMap into the operator itself, so OIDC discovery against a Keycloak
behind a private CA succeeds; it also becomes the operator's
`--ca-bundle-configmap`, which mounts the same ConfigMap into every analysis's
vice-proxy sidecar at `de_ca_bundle_mount_path` and sets `SSL_CERT_FILE`.
vice-proxy needs it for the back-channel token exchange, which is a server-side
call that the browser's trust in the certificate does not help with. The
ConfigMap must therefore live in `vice_ns` — analyses run there too, and a
ConfigMap cannot be referenced across namespaces. Empty, the default, adds no
volume, no mount, and no variable, so environments with publicly trusted
certificates are unaffected.

Setting it requires an app-exposer image that understands the flag. Support
landed in app-exposer PR #164, after the `v2026.08.04` release the build
descriptor currently pins, so an older image exits at startup on an unknown
flag and the operator crash-loops. Leave the variable empty until the pinned
image is built from app-exposer `main` or later.

This role owns the `vice_ns` copy; `k8s_de_reqs` publishes the DE namespace's
under `de_ca_bundle_configmap`. They are separate because the two names can
differ, and one object reconciled by two roles is worse than two objects. The
key, mount path and `--ca-bundle-key` flag all derive from `de_ca_bundle_key`
and `de_ca_bundle_mount_path`, so overriding either stays consistent across the
ConfigMap the role writes and the manifest that reads it.

## Registration with app-exposer

Deploying the operator does not make it usable. app-exposer schedules VICE
launches onto the operators listed in the `operators` table of the DE database
and reconciles that list into its scheduler every few minutes; it does not
discover them. Until a row exists the operator is invisible, and a launch fails
with `no operators configured` while the operator's own logs show nothing but
successful health probes — the failure names neither the operator nor the table.

`vice_operators_values` supplies the rows and `tasks/register.yml` creates them
through app-exposer's admin API (`POST /vice/admin/operators`, over a
port-forward, since the admin routes are internal) rather than by INSERT, so the
field validation and the server-assigned id come from the service that owns the
table. Each entry needs `name`, `url` — how app-exposer reaches the operator
inside the cluster — and `base_url`, the operator's public address;
`tls_skip_verify` and `priority` are optional. Registration matches on name, so
re-running is a no-op; an entry whose `url` changed is left alone rather than
silently rewritten.

The default is empty, because QA and prod already have their rows. A deployment
building the database from nothing has to list its own.

The `porklock-config` Secret is populated from the same `irods_host`,
`irods_user`, `irods_password`, `irods_zone`, and `irods_port` inventory
variables used by the Argo role's `irods-config` ConfigMap. It is required
when any VICE analysis runs with `mount_data_store=false` (porklock
file-transfer mode).

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags vice-operator
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md) and
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md).

# Citations

1. `ansible/roles/services/vice-operator/files/vice-operator.json` — build descriptor: the app-exposer image, pinned by digest.
2. `ansible/roles/services/vice-operator/tasks/build.yml` — builds from the app-exposer source repo via `source_service`.
3. `ansible/roles/services/vice-operator/tasks/main.yml` — namespace, service account, Role/ClusterRole, `porklock-config` Secret, and direct k8s deploy.
4. `ansible/roles/services/vice-operator/templates/vice_operator.yml.j2` — secret, optional repos ConfigMap, and the flag-driven Deployment.
5. `ansible/roles/services/vice-operator/files/repos.json` — image mirror list for `manual-mirror` cache mode.
6. `ansible/roles/common/defaults/main.yml` — `vice_operator_ca_bundle_configmap` and the shared `de_ca_bundle_*` settings it defaults from.
