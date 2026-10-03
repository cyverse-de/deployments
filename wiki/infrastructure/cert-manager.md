---
type: Service
title: cert-manager
description: How cert-manager is installed via Helm and which ClusterIssuers the deployment creates for self-signed and Let's Encrypt certificates.
resource: /ansible/roles/cert-manager
tags: [cert-manager, tls, certificates, letsencrypt, issuers, kubernetes.yml]
timestamp: 2026-10-02T00:00:00Z
---

cert-manager issues and renews the TLS certificates used inside the cluster — the Traefik default
certificate, the DE UI, VICE wildcard, user portal, Keycloak, Harbor, and (when exposed) Grafana certs. For the full
certificate inventory and expiry procedures, see
[Certificate Management](/playbooks/certificate-management.md).

## Installation

The `cert-manager` role runs in `kubernetes.yml` under the `cert-manager` tag, from the play that
targets `k8s_controllers[0]` with a local connection. It installs the `jetstack/cert-manager` Helm
chart into the `cert-manager` namespace with `installCRDs: true` and Prometheus metrics disabled,
then waits (up to 300s each) for the `cert-manager`, `cert-manager-webhook`, and
`cert-manager-cainjector` deployments to become Available before continuing.

## Issuers

The `cluster_issuers` role runs immediately after cert-manager in `kubernetes.yml` (tags
`cert-issuers` and `de-reqs`) so that certificates requested later in the run — Harbor's and
Traefik's — can be issued right away. It creates:

- `default-cluster-issuer` — a ClusterIssuer that Traefik and the per-namespace CA certificates
  chain off (see [Ingress](/infrastructure/ingress.md)). `cluster_issuer_default_type` decides how
  it signs: `selfSigned` (the default) generates a throwaway root, and `ca` loads an existing CA
  keypair from `cluster_issuer_ca_cert_file` / `cluster_issuer_ca_key_file` on the control machine
  into a Secret in the `cert-manager` namespace and issues from that instead. That root must
  permit at least one intermediate (`pathlen` >= 1), because the `selfsigned` provider inserts a
  per-endpoint CA between the root and each leaf: a `pathlen:0` root — which is what **mkcert**
  generates — yields certificates cert-manager reports as `Ready` while every client rejects the
  chain with `path length constraint exceeded`. The `ca` variant is
  what makes locally-issued certificates come out browser-trusted when the root is already in the
  trust store — see [Local Single-Node Deployment](/playbooks/local-single-node-deployment.md).
  It also means whoever can read secrets in the `cert-manager` namespace holds the CA, so it
  belongs on a workstation rather than a shared cluster.
- A Let's Encrypt ClusterIssuer (name from `cert_manager_le_issuer_name`, default `letsencrypt`),
  created only when at least one endpoint's provider is `letsencrypt` (see
  [Choosing a provider per endpoint](#choosing-a-provider-per-endpoint)). It uses the ACME `dns01` solver
  against AWS Route53, so the role also creates a Secret in the `cert-manager` namespace holding
  `cert_manager_le_aws_access_key_id` / `cert_manager_le_aws_secret_access_key`.

A separate namespaced self-signed `default-issuer` is created in the DE namespace (`ns`) by
`ansible/roles/k8s_de_reqs/tasks/issuers.yml` under the `de-reqs` tag, since it needs the DE
namespace to exist first.

## Endpoint certificates: the tls_certificate role

Every role that needs a certificate for a public endpoint — `kubernetes_ingress` (DE, user
portal, AI Discovery Lab, VICE), `harbor`, `keycloak_install`, and `grafana` — creates it by
including the `tls_certificate` role rather than writing its own Certificate tasks. The caller
passes the Certificate/Secret name, namespace, hostnames, durations, and its endpoint's
provider, and the role creates what that provider calls for:

- `selfsigned` — a CA Certificate (chained off `default-cluster-issuer`), a namespaced
  `Issuer` backed by it, and a leaf Certificate signed by that Issuer. The portal and AI
  Discovery Lab pass the DE's CA and Issuer names, so the three share one chain, and
  whichever of them is self-signed creates it even when the DE itself is not.
  The leaf also covers `localhost` unless the caller overrides
  `tls_certificate_selfsigned_dns_names` (Keycloak adds its in-cluster service names;
  Grafana leaves `localhost` out).
- `letsencrypt` — a Certificate from the Let's Encrypt ClusterIssuer for the given
  hostnames, the first being the common name.
- `external` — no cert-manager resources. The role writes the caller's PEM certificate and
  key (`tls_certificate_pem`, `tls_certificate_key_pem`) into a `kubernetes.io/tls` Secret,
  replacing it outright on each run, and deletes any cert-manager Certificate of the same
  name, so an endpoint switched from another provider is not overwritten by cert-manager.

The role fails before creating anything if its provider is not one of these three, or if
the parameters that provider needs are empty — namespace and hostnames for `selfsigned` and
`letsencrypt` (plus the CA and Issuer names for `selfsigned`), and namespace, certificate, and
key for `external`.

## Choosing a provider per endpoint

Each public endpoint has its own provider variable, defaulting to `cert_manager_provider`, so
a deployment can mix providers — for example, Let's Encrypt for CyVerse hostnames and
`external` for a University of Arizona hostname whose certificate the university issues:

| Variable | Endpoint |
|---|---|
| `de_tls_provider` | `de_hostname` |
| `user_portal_tls_provider` | `portal_hostname` |
| `vice_tls_provider` | `vice_wildcard_fqdn` |
| `ai2s_tls_provider` | `ai2s_hostname` |
| `harbor_tls_provider` | `harbor_fqdn` |
| `keycloak_tls_provider` | `keycloak_hostname` |
| `grafana_tls_provider` | `grafana_hostname` |

`cert_manager_endpoint_provider_settings` maps each of the seven variables to its value.
`cluster_issuers` first checks those values and `cert_manager_provider` against
`cert_manager_supported_providers`, and fails on any it doesn't recognize, naming the
variable. That catches a typo in, say, `harbor_tls_provider` on any run that includes the
issuers, without waiting for the explicitly tagged `harbor` role to run. It then creates the
Let's Encrypt ClusterIssuer and its Route53 Secret when any endpoint uses `letsencrypt`. For an
`external` endpoint, the operator sets the endpoint's certificate and key variables
(for example `de_tls_cert_pem` and `de_tls_cert_key_pem`; `ansible/README.md` lists all seven
pairs) and the playbooks create the Secret. cert-manager does not renew these, so renewing
one means updating the variables and rerunning the play that owns the endpoint.

## Key variables

All defaults live in `ansible/roles/common/defaults/main.yml` (every role depends on `common`):

- `cert_manager_provider` — `selfsigned` (default), `letsencrypt`, or `external`; derived from
  the legacy `cert_manager_use_letsencrypt` boolean for backward compatibility. It is the
  default for each endpoint's `*_tls_provider`.
- `cluster_issuer_default_type` — `selfSigned` (default) or `ca`. Orthogonal to
  `cert_manager_provider`: it changes what the `selfsigned` chain's root *is*, not which issuer the
  endpoint certificates reference.
- `cluster_issuer_ca_cert_file`, `cluster_issuer_ca_key_file`, `cluster_issuer_ca_secret_name` —
  read only when the type is `ca`.
- `cert_manager_le_aws_region`, `cert_manager_le_aws_access_key_id`,
  `cert_manager_le_aws_secret_access_key` — Route53 credentials for the dns01 solver; the key ID
  and secret default to `replace_me` and must be set in group_vars for Let's Encrypt.
- `cert_manager_le_issuer_email` (defaults to `email_dest`) and
  `cert_manager_le_issuer_acme_server` (the production Let's Encrypt v2 endpoint).

Operators should note that `cert_manager_provider` changes which issuer every endpoint
certificate references, not just this role's issuers, unless an endpoint overrides it.

# Citations

[1] `ansible/roles/cert-manager/tasks/main.yml` — Helm install and deployment availability waits.
[2] `ansible/roles/cluster_issuers/tasks/main.yml` — self-signed and Let's Encrypt ClusterIssuers, Route53 secret.
[3] `ansible/kubernetes.yml` — role ordering and the `cert-manager` / `cert-issuers` tags.
[4] `ansible/roles/common/defaults/main.yml` — `cert_manager_*` variable defaults.
[5] `ansible/roles/k8s_de_reqs/tasks/issuers.yml` — namespaced `default-issuer` in the DE namespace.
[6] `ansible/roles/tls_certificate/` — the shared endpoint-certificate role and its parameters.
[8] `ansible/README.md` — the per-endpoint certificate and key variables for `external` endpoints.
[7] `ansible/example/inventory/group_vars/all.yaml` — the per-endpoint provider overrides and the certificate and key variables an `external` endpoint needs.
