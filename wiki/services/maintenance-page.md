---
type: Service
title: maintenance-page
description: Maintenance-mode page that redirects DE traffic to itself by rewriting the environment's Gateway API HTTPRoutes.
resource: /ansible/roles/services/maintenance-page
tags: [maintenance, gateway-api, httproute, rbac]
timestamp: 2026-07-20T00:00:00Z
---

maintenance-page serves a maintenance page during outages and is unusual in
that it manipulates cluster routing itself: the role creates a
`maintenance-page` ServiceAccount, ClusterRole, and ClusterRoleBinding
granting `get`/`create` on Services and `get`/`update` on
`gateway.networking.k8s.io` HTTPRoutes (see
[ingress](/infrastructure/ingress.md)), so the pod can repoint the
environment's routes at itself. It runs with `--namespace=$(DE_ENV)` where
`DE_ENV` comes from the `configs` secret, along with `BASIC_AUTH_USERNAME`
and `BASIC_AUTH_PASSWORD` (basic auth guards the admin function). It listens
on port 8080 (`http`, probed at `/healthz`) and 8081 (`admin`). Single
replica by default.

- **Source repo:** [cyverse-de/maintenance-page](https://github.com/cyverse-de/maintenance-page)
- **Image:** `harbor.cyverse.org/de/maintenance-page` (pinned in
  `files/maintenance-page.json`, pulled with `imagePullPolicy: Always`)

## Configuration

This role has no config template or per-service secret — all runtime
configuration arrives through the three environment variables above. The
manifest template is `templates/k8s/maintenance-page.yaml.j2` (note the
`.yaml` extension; the role passes `manifest_file: maintenance-page.yaml` to
the deploy-service role explicitly). The only role default is
`maintenance_page_replicas: 1`. The k8s manifest defines the Deployment only;
the RBAC objects are created directly by the role's tasks.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags maintenance-page
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/maintenance-page/tasks/main.yml` — ServiceAccount, ClusterRole (services + HTTPRoutes), ClusterRoleBinding, explicit `manifest_file`.
2. `ansible/roles/services/maintenance-page/templates/k8s/maintenance-page.yaml.j2` — env vars from the `configs` secret, ports, `/healthz` probes.
3. `ansible/roles/services/maintenance-page/files/maintenance-page.json` — image and pinned tag/digest.
