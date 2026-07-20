---
type: Service
title: cert-manager
description: How cert-manager is installed via Helm and which ClusterIssuers the deployment creates for self-signed and Let's Encrypt certificates.
resource: /ansible/roles/cert-manager
tags: [cert-manager, tls, certificates, letsencrypt, issuers, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

cert-manager issues and renews the TLS certificates used inside the cluster — the Traefik default
certificate, the DE UI, VICE wildcard, user portal, Keycloak, and Harbor certs. For the full
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

- `default-cluster-issuer` — a self-signed ClusterIssuer, created unconditionally. Traefik and the
  per-namespace CA certificates chain off this issuer (see [Ingress](/infrastructure/ingress.md)).
- A Let's Encrypt ClusterIssuer (name from `cert_manager_le_issuer_name`, default `letsencrypt`),
  created only when `cert_manager_provider` is `letsencrypt`. It uses the ACME `dns01` solver
  against AWS Route53, so the role also creates a Secret in the `cert-manager` namespace holding
  `cert_manager_le_aws_access_key_id` / `cert_manager_le_aws_secret_access_key`.

A separate namespaced self-signed `default-issuer` is created in the DE namespace (`ns`) by
`ansible/roles/k8s_de_reqs/tasks/issuers.yml` under the `de-reqs` tag, since it needs the DE
namespace to exist first.

## Key variables

All defaults live in `ansible/roles/common/defaults/main.yml` (every role depends on `common`):

- `cert_manager_provider` — `selfsigned` (default) or `letsencrypt`; derived from the legacy
  `cert_manager_use_letsencrypt` boolean for backward compatibility.
- `cert_manager_le_aws_region`, `cert_manager_le_aws_access_key_id`,
  `cert_manager_le_aws_secret_access_key` — Route53 credentials for the dns01 solver; the key ID
  and secret default to `replace_me` and must be set in group_vars for Let's Encrypt.
- `cert_manager_le_issuer_email` (defaults to `email_dest`) and
  `cert_manager_le_issuer_acme_server` (the production Let's Encrypt v2 endpoint).

Operators should note that choosing `letsencrypt` changes which issuer the DE, VICE, portal, and
Harbor certificates reference throughout the deployment, not just this role.

# Citations

[1] `ansible/roles/cert-manager/tasks/main.yml` — Helm install and deployment availability waits.
[2] `ansible/roles/cluster_issuers/tasks/main.yml` — self-signed and Let's Encrypt ClusterIssuers, Route53 secret.
[3] `ansible/kubernetes.yml` — role ordering and the `cert-manager` / `cert-issuers` tags.
[4] `ansible/roles/common/defaults/main.yml` — `cert_manager_*` variable defaults.
[5] `ansible/roles/k8s_de_reqs/tasks/issuers.yml` — namespaced `default-issuer` in the DE namespace.
