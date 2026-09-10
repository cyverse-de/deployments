---
type: Service
title: Harbor
description: How the Harbor container registry is deployed via its Helm chart in kubernetes.yml, including TLS, Gateway/Ingress exposure, and its external PostgreSQL databases.
resource: /ansible/roles/harbor
tags: [harbor, registry, helm, tls, kubernetes.yml]
timestamp: 2026-09-10T00:00:00Z
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

## Authenticating to the registry

`registry_hostname` (default `harbor.cyverse.org`) names the registry that
builds push to and deploys pull from. The CyVerse instance runs in Harbor's
OIDC authentication mode, which changes how `docker login` works. The mode is
readable without credentials:

```bash
curl -s https://harbor.cyverse.org/api/v2.0/systeminfo | jq .auth_mode
# "oidc_auth"
```

In `oidc_auth` mode Harbor rejects an OIDC user's password at the registry
endpoint, because the Docker CLI cannot carry out an interactive OIDC flow.
Harbor issues each user a **CLI secret** for this purpose, found in the web UI
under the username menu, *User Profile*. Supplying the account password instead
fails with no detail beyond a bare `unauthorized:`:

```
Error response from daemon: Get "https://harbor.cyverse.org/v2/": unauthorized:
```

Two things produce that same message, so check both:

- The password was used rather than the CLI secret.
- The username was wrong. Harbor derives it from an OIDC claim, so it need not
  match the identity provider's login name; the *User Profile* page shows the
  value Harbor expects.

The `harbor` role does not manage this. It installs the chart and wires up TLS
and the databases, and configures no authentication mode at all — `auth_mode`
is Harbor's own configuration, changed through Harbor rather than through
Ansible.

For anything automated, prefer a **robot account** scoped to the project over a
personal CLI secret. A CLI secret is bound to one user's OIDC identity and stops
working the moment it is regenerated, whereas a robot secret is stable and can
be restricted to push or pull alone. This is already the pattern for the
cluster's image-pull secret, built from `harbor_robot_name` and
`harbor_robot_secret`.

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

[6] `ansible/roles/common/defaults/main.yml` — `registry_hostname`, the default `harbor.cyverse.org` that `harbor_fqdn` and `harbor_url` derive from.

[7] [Harbor OIDC authentication](https://goharbor.io/docs/latest/administration/configure-authentication/oidc-auth/) — upstream documentation of the CLI secret and `oidc_auth` mode.
