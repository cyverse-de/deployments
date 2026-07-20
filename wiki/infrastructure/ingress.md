---
type: Service
title: Ingress and Gateway Routing
description: Traefik (Gateway API) is the primary edge for DE traffic, with ingress-nginx available for Ingress-based exposure; the kubernetes_ingress role defines the DE, portal, and VICE gateways and routes.
resource: /ansible/roles/kubernetes_ingress
tags: [ingress, traefik, gateway-api, ingress-nginx, routing, vice, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

The deployment's primary in-cluster edge is Traefik acting as a Kubernetes Gateway API provider:
`gateway_provider` defaults to `"traefik"` and `gateway_class_name` to `"traefik"` in
`ansible/roles/common/defaults/main.yml`. ingress-nginx is also installed and is used for
classic Ingress exposure (Harbor uses it when `gateway_provider` is not `traefik`). External
traffic typically reaches these controllers' NodePorts through [HAProxy](/infrastructure/haproxy.md).

## Controllers

Both controller roles run in `kubernetes.yml` from the `k8s_controllers[0]` play, ahead of Harbor
so it can be fronted by either mechanism:

- `ingress_nginx` (tags `ingress-nginx`, `de-reqs`) — installs the `ingress-nginx/ingress-nginx`
  Helm chart into the `ingress-nginx` namespace as a NodePort service on
  `ingress_nginx_http_port` (31343) and `ingress_nginx_https_port` (31344). Installed
  unconditionally.
- `traefik` (tags `traefik`, `de-reqs`; only when `gateway_provider == "traefik"`) — installs the
  Gateway API CRDs (`gateway_api_crd_version`, v1.5.1, which must stay in step with the Traefik
  version — Traefik v3.7 blocks at startup waiting for the TLSRoute CRD), creates a self-signed CA,
  Issuer, and default TLS certificate via cert-manager in the `traefik` namespace, then installs
  the `traefik/traefik` Helm chart with the `kubernetesGateway` provider enabled. It listens on
  NodePorts `traefik_http_port` (31380) and `traefik_https_port` (31383), with 24h read/write
  timeouts and `allowEncodedSlash: true` (required for the VICE loading page).

There is no `traefik.yml` standalone playbook; both roles run only via `kubernetes.yml`.

## Routes: the kubernetes_ingress role

The `kubernetes_ingress` role (tag `ingress`) defines the actual routing for the DE. It creates
cert-manager Certificates (self-signed CA chain or Let's Encrypt, per `cert_manager_provider` —
see [cert-manager](/infrastructure/cert-manager.md)) and Gateway API resources:

- A `discoenv` Gateway for `de_hostname` plus an HTTPRoute sending `/anon-files` and `/dl` to
  kifshare, `/terrain` to terrain, `/job` to job-status-listener (prefix rewritten to `/`),
  `/formation` and the root-form OAuth discovery paths (`/.well-known/...`) to formation, and
  everything else to sonora. When Traefik is the provider, a variant of the route attaches
  CORS-header Middlewares; a provider-neutral variant applies otherwise.
- A `portal` Gateway for `portal_hostname` routing to `user-portal` on port 3000.
- A `vice` Gateway for `vice_wildcard_fqdn` that only admits HTTPRoutes from namespaces labeled
  `has-vice-routes: "true"`, with a default route to `vice-default-backend`.

It also deletes the legacy `discoenv` and `portal-ingress` Ingress objects left over from the
Ingress-based setup. Certificates for the DE, portal, and VICE all land in the DE namespace `ns`.

# Citations

[1] `ansible/roles/ingress_nginx/tasks/main.yml` — ingress-nginx Helm install and NodePorts.
[2] `ansible/roles/traefik/tasks/main.yml` — Gateway API CRDs, Traefik CA/cert, Helm values.
[3] `ansible/roles/kubernetes_ingress/tasks/gateway_api.yml` — DE, portal, and VICE gateways, routes, and certificates.
[4] `ansible/roles/kubernetes_ingress/tasks/ingresses.yml` — removal of the legacy Ingress objects.
[5] `ansible/kubernetes.yml` — role ordering, tags, and the `gateway_provider` condition on Traefik.
[6] `ansible/roles/common/defaults/main.yml` — `gateway_provider`, `gateway_class_name`, port and cert variable defaults.
[7] `ansible/roles/harbor/tasks/main.yml` — Harbor's choice between Gateway route and ingress-nginx Ingress exposure.
