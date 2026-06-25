# Expose Harbor via ingress/gateway with cert-manager TLS

Date: 2026-06-25
Ticket: CORE-2156

## Context

The `harbor` role installs the Harbor container registry and currently exposes
it via NodePort (`expose.type: nodePort`, chart TLS disabled). NodePort is
inconvenient: it bypasses the cluster's gateway/ingress layer and provides no
managed TLS, so certificate maintenance is manual.

Earlier CORE-2156 work moved Harbor and the gateway/ingress controllers
(`ingress_nginx`, `traefik`) ahead of the `k8s_de_reqs` (de-reqs) pass, so the
controllers are now available before Harbor installs. This makes it possible to
front Harbor with an Ingress or a Gateway route and to manage its TLS with
cert-manager.

Goal: serve Harbor at `harbor_fqdn` (default `harbor.cyverse.org`) through the
existing controllers, with cert-manager-managed TLS so renewals — self-signed or
Let's Encrypt — happen automatically.

## Decisions

1. **Exposure is chosen by `gateway_provider`:**
   - `traefik` → Gateway API. Harbor runs as `clusterIP`; a hand-written
     `harbor` Gateway + HTTPRoute (`gatewayClassName: traefik`) in the `harbor`
     namespace route to it, with TLS terminated at the HTTPS listener. This
     matches how DE/portal/vice are exposed (the `kubernetes_ingress` role). The
     Harbor Helm chart cannot emit a Gateway API HTTPRoute, so these resources
     are created by the role directly.
   - otherwise (ingress-nginx) → the Harbor chart's own `expose.type: ingress`
     with `className: {{ harbor_ingress_class_name }}` (default `nginx`) and TLS
     via `certSource: secret` pointing at the cert-manager-managed secret.

2. **TLS uses an explicit cert-manager `Certificate`, CA-chain in self-signed
   mode** (mirroring `roles/kubernetes_ingress/tasks/gateway_api.yml`):
   - self-signed (`not cert_manager_use_letsencrypt`):
     `harbor-selfsigned-ca` (issuerRef `default-cluster-issuer`) →
     `harbor-ca-issuer` (namespaced CA Issuer) → `harbor-tls`.
   - Let's Encrypt (`cert_manager_use_letsencrypt`): `harbor-tls` issued directly
     from the `letsencrypt` ClusterIssuer.
   Trusting the one long-lived CA (self-signed mode) covers renewals, which
   matters for docker/podman clients pulling from the registry.

3. **Cluster issuers move ahead of Harbor.** Harbor's cert chain references
   `default-cluster-issuer` / the `letsencrypt` ClusterIssuer, which today are
   created inside `k8s_de_reqs` (de-reqs) — now *after* Harbor. The cluster-scoped
   issuers move into a new `cluster_issuers` role that runs right after
   `cert-manager`, so `harbor-tls` (and Traefik's existing cert) issue
   immediately and a standalone `--tags harbor` run yields working TLS.

## Component design

### 1. `cluster_issuers` role (new)

Split `roles/k8s_de_reqs/tasks/issuers.yml`:

- **Moves to `roles/cluster_issuers/`** (run after `cert-manager`, before the
  controllers and Harbor):
  - self-signed `default-cluster-issuer` (ClusterIssuer), always.
  - when `cert_manager_use_letsencrypt`: the Route53 credentials secret (in the
    `cert-manager` namespace) and the `letsencrypt` ClusterIssuer.
- **Stays in `k8s_de_reqs`** (`issuers.yml`): the namespaced `default-issuer`
  (Issuer in `ns`) — it depends on the DE namespace created earlier in de-reqs,
  and nothing else references it.

`meta/main.yml` depends on `common`. Playbook tags: `cert-issuers` + `de-reqs`
(so `--tags de-reqs` still creates the cluster issuers).

### 2. Harbor cert chain — `roles/harbor/tasks/certs.yml` (new)

Mirrors the DE pattern, in the `harbor` namespace. Self-signed branch
(`when: not cert_manager_use_letsencrypt`):

- `harbor-selfsigned-ca` Certificate: `isCA: true`, `issuerRef`
  `default-cluster-issuer` (ClusterIssuer), ECDSA 256, duration
  `harbor_tls_ca_duration`, renewBefore `harbor_tls_ca_renew_before`.
- `harbor-ca-issuer` Issuer: `ca.secretName: harbor-selfsigned-ca`.
- `harbor-tls` Certificate: `issuerRef` `harbor-ca-issuer` (Issuer),
  `dnsNames: [localhost, "{{ harbor_fqdn }}"]`, `commonName: harbor_fqdn`,
  duration `harbor_tls_cert_duration`, renewBefore `harbor_tls_cert_renew_before`.

Let's Encrypt branch (`when: cert_manager_use_letsencrypt`):

- `harbor-tls` Certificate: `issuerRef` `{{ cert_manager_le_issuer_name }}`
  (ClusterIssuer), `dnsNames: ["{{ harbor_fqdn }}"]`.

Both branches produce the `harbor-tls` secret in the `harbor` namespace.

### 3. Harbor Helm `expose` change — `roles/harbor/tasks/main.yml`

Keep `externalURL: "https://{{ harbor_fqdn }}"`. Compute the `expose` block with a
`set_fact` keyed on `gateway_provider` so the long `values:` block stays a single
helm task, then reference `expose: "{{ harbor_expose }}"`.

- ingress-nginx (`gateway_provider != "traefik"`):
  ```yaml
  type: ingress
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: "{{ harbor_tls_cert_name }}"
  ingress:
    className: "{{ harbor_ingress_class_name }}"
    hosts:
      core: "{{ harbor_fqdn }}"
  ```
- traefik:
  ```yaml
  type: clusterIP
  tls:
    enabled: false
  ```

### 4. Harbor Gateway + HTTPRoute — `roles/harbor/tasks/gateway.yml` (new, traefik only)

`when: gateway_provider == "traefik"`:

- `harbor` Gateway (namespace `harbor`, `gatewayClassName: {{ gateway_class_name }}`):
  HTTP listener (port 8000) and HTTPS listener (port 8443,
  `tls.certificateRefs` → `harbor-tls` Secret), both for hostname `harbor_fqdn`.
- `harbor` HTTPRoute: `parentRefs: [harbor]`, `hostnames: [harbor_fqdn]`,
  backendRef to the Harbor clusterIP service.

**To confirm at implementation:** the Harbor chart's clusterIP service name and
port (expected service `harbor`, port `80`).

### 5. Role wiring & playbook ordering

`roles/harbor/tasks/main.yml` order: include `certs.yml` → helm install →
include `gateway.yml` (traefik only). In `kubernetes.yml` the order becomes:
`cert-manager` → `cluster_issuers` → `ingress_nginx` → `traefik` → `longhorn` →
`harbor` → `k8s_de_reqs`. Harbor's prerequisites (cert-manager, cluster issuers,
the active controller) all precede it.

### 6. Variables (`roles/common/defaults/main.yml`)

- Add: `harbor_ingress_class_name: nginx`, `harbor_tls_cert_name: harbor-tls`,
  `harbor_tls_ca_name: harbor-selfsigned-ca`,
  `harbor_tls_issuer_name: harbor-ca-issuer`, `harbor_tls_ca_duration: 8766h`,
  `harbor_tls_ca_renew_before: 240h`, `harbor_tls_cert_duration: 2160h`,
  `harbor_tls_cert_renew_before: 240h`.
- Remove (now unused): `harbor_http_nodeport`, `harbor_https_nodeport`.
- Reused as-is: `harbor_fqdn`, `gateway_class_name`, `gateway_provider`,
  `cert_manager_use_letsencrypt`, `cert_manager_le_issuer_name`.

### 7. Documentation — `example/inventory/group_vars/all.yaml`

- Rewrite the "In-cluster registry: Harbor" section: exposure is now
  ingress/gateway (chosen by `gateway_provider`) with cert-manager TLS; document
  `harbor_ingress_class_name` and the `harbor_tls_*` variables; drop the NodePort
  variables.
- Add documentation for the new `cluster_issuers` step and adjust the Phase 7 /
  issuers notes to reflect that the cluster-scoped issuers moved earlier (only
  the namespaced `default-issuer` remains in de-reqs).

## Testing / verification

- `ansible-playbook --syntax-check -i example/inventory kubernetes.yml`.
- On a cluster:
  - `harbor-tls` secret is issued in the `harbor` namespace in both self-signed
    and (if enabled) Let's Encrypt modes.
  - traefik: the `harbor` Gateway is programmed and the HTTPRoute attaches;
    ingress-nginx: the Harbor Ingress is created referencing `harbor-tls`.
  - `https://harbor_fqdn` serves the Harbor UI with the managed certificate.
  - `podman login harbor_fqdn` (or `docker login`) succeeds and an image
    push/pull round-trips.

## Out of scope

- Changing how DE/portal/vice are exposed (already Gateway API).
- Migrating other NodePort-exposed services.
- HTTP→HTTPS redirect behavior beyond chart/controller defaults.
