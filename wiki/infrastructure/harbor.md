---
type: Service
title: Harbor
description: How the Harbor container registry is deployed via its Helm chart in kubernetes.yml, including TLS, Gateway/Ingress exposure, and its external PostgreSQL databases.
resource: /ansible/roles/harbor
tags: [harbor, registry, helm, tls, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

Harbor is the container image registry for a DE deployment. The `harbor` role installs the
upstream Helm chart (`harbor_chart_version`, currently 1.19.1) into the `harbor_namespace`
(default `harbor`), with `externalURL` set to `https://{{ harbor_fqdn }}`. `harbor_fqdn` and
`harbor_url` both default to `registry_hostname`.

## Installation

The role runs in `kubernetes.yml` under the `harbor` tag, and only when that tag is passed
explicitly (`when: "'harbor' in ansible_run_tags"`):

```bash
ansible-playbook -i <inventory> --tags harbor kubernetes.yml
```

Ordering in `kubernetes.yml` matters: the gateway/ingress controllers and
[Longhorn](/infrastructure/longhorn.md) install ahead of Harbor (its PVCs use the
`longhorn` StorageClass via `harbor_storage_class`), and the `de-reqs` phase runs after
Harbor because it creates the DE image-pull secret from a Harbor robot account
(`harbor_robot_name`/`harbor_robot_secret`) that has to exist in a running Harbor first.

## TLS and exposure

`certs.yml` requests the Harbor TLS certificate from [cert-manager](/infrastructure/cert-manager.md).
With `cert_manager_provider: selfsigned` it builds a chain (CA certificate, a namespaced
`Issuer`, then the `harbor-tls` certificate); with `letsencrypt` it requests `harbor-tls`
directly from the `cert_manager_le_issuer_name` ClusterIssuer.

Exposure depends on `gateway_provider` (see [Ingress](/infrastructure/ingress.md)):

- `traefik`: the role creates a Gateway API `Gateway` named `harbor` (HTTP on 8000, HTTPS on
  8443 terminating TLS with `harbor-tls`) before installing the chart, and the chart is
  configured with `expose.type: route` so it emits an `HTTPRoute` attached to that Gateway.
- anything else: the chart's own `Ingress` is used (`harbor_ingress_class_name`, default
  `nginx`), terminating TLS with the `harbor-tls` secret.

## Database

Harbor uses the external [PostgreSQL](/infrastructure/postgresql.md) server (the first host
in the `dbms` inventory group, port `pg_listen_port`) rather than the chart's bundled
database. The databases and credentials come from `harbor_core_db_name`,
`harbor_clair_db_name`, `harbor_notary_server_db_name`, `harbor_notary_signer_db_name`,
`harbor_database_user`, and `harbor_database_password`; the connection uses
`sslMode: disable`. Most components run with `harbor_replicas` replicas (default 2), and the
registry/chartmuseum/jobservice PVCs are `ReadWriteMany` on `harbor_storage_class`.

# Citations

[1] `ansible/roles/harbor/tasks/main.yml` — namespace, Helm install, exposure selection, external database wiring.
[2] `ansible/roles/harbor/tasks/certs.yml` — self-signed CA/issuer chain vs. Let's Encrypt certificate.
[3] `ansible/roles/harbor/tasks/gateway.yml` — the Gateway created for Traefik exposure.
[4] `ansible/kubernetes.yml` — the `harbor` tag, explicit-tag guard, and ordering relative to Longhorn and de-reqs.
[5] `ansible/roles/common/defaults/main.yml` — `harbor_*` variable defaults.
