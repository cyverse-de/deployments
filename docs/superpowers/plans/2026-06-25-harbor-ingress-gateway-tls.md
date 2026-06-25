# Harbor ingress/gateway TLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Harbor's NodePort exposure with ingress-nginx (standard Ingress) or Traefik (Gateway API) routing, with cert-manager-managed TLS.

**Architecture:** Exposure is chosen by `gateway_provider`. The Harbor Helm chart's `expose` block is built per-provider (clusterIP for Traefik, ingress for ingress-nginx). TLS is an explicit cert-manager `Certificate` (`harbor-tls`) — a CA chain in self-signed mode, direct from the `letsencrypt` ClusterIssuer in LE mode. The cluster-scoped issuers move into a new `cluster_issuers` role that runs before Harbor so the cert issues immediately.

**Tech Stack:** Ansible (`kubernetes.core` collection), Harbor Helm chart, cert-manager, Gateway API, Traefik, ingress-nginx.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-25-harbor-ingress-gateway-tls-design.md`.
- All commit subjects use the `CORE-2156:` prefix.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Work on branch `document-openldap-group-vars` (current stacked CORE-2156 branch).
- Every cluster-touching task delegates to localhost with `KUBECONFIG` from the environment (existing pattern).
- There is no unit-test harness. The per-task "test" is `ansible-playbook --syntax-check -i example/inventory kubernetes.yml` (run from `ansible/`), plus targeted greps / `ruby -ryaml` no-op checks. A pre-existing `community.postgresql.postgresql_set` DEPRECATION WARNING is expected and not a failure; success = final line `playbook: kubernetes.yml` with no ERROR.
- All paths below are relative to `/Users/sarahr/src/de/deployments/ansible` unless noted. The git root is `/Users/sarahr/src/de/deployments`.
- Variable default values to reuse verbatim (mirroring `de_tls_*`): CA duration `8766h`, CA renewBefore `240h`, cert duration `2160h`, cert renewBefore `240h`.

---

## File Structure

- Create `roles/cluster_issuers/meta/main.yml` — role metadata (depends on `common`).
- Create `roles/cluster_issuers/tasks/main.yml` — cluster-scoped issuers (self-signed `default-cluster-issuer`; LE route53 secret + ClusterIssuer).
- Modify `roles/k8s_de_reqs/tasks/issuers.yml` — keep only the namespaced `default-issuer`.
- Modify `kubernetes.yml` — add `cluster_issuers` role after `cert-manager`.
- Modify `roles/common/defaults/main.yml` — add `harbor_tls_*` + `harbor_ingress_class_name`; remove `harbor_http_nodeport`/`harbor_https_nodeport`.
- Create `roles/harbor/tasks/certs.yml` — `harbor-tls` cert chain.
- Create `roles/harbor/tasks/gateway.yml` — `harbor` Gateway + HTTPRoute (Traefik only).
- Modify `roles/harbor/tasks/main.yml` — include certs, build `expose` per-provider, include gateway.
- Modify `example/inventory/group_vars/all.yaml` — docs.

---

## Task 1: Move cluster-scoped issuers into a `cluster_issuers` role

**Files:**
- Create: `roles/cluster_issuers/meta/main.yml`
- Create: `roles/cluster_issuers/tasks/main.yml`
- Modify: `roles/k8s_de_reqs/tasks/issuers.yml`
- Modify: `kubernetes.yml`

**Interfaces:**
- Produces: cluster-scoped `ClusterIssuer/default-cluster-issuer` (self-signed) and, when `cert_manager_use_letsencrypt`, `ClusterIssuer/{{ cert_manager_le_issuer_name }}`, created right after `cert-manager` and before the controllers/Harbor. Later tasks (Harbor cert chain, Traefik cert) reference these by name.

- [ ] **Step 1: Create the role metadata**

Create `roles/cluster_issuers/meta/main.yml`:

```yaml
---
dependencies:
  - role: common
```

- [ ] **Step 2: Create the cluster_issuers tasks**

Create `roles/cluster_issuers/tasks/main.yml`:

```yaml
---
- name: Apply cluster-scoped self-signed issuer
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  block:
    - name: Apply default-cluster-issuer
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: ClusterIssuer
          metadata:
            name: default-cluster-issuer
          spec:
            selfSigned: {}

- name: Apply Let's Encrypt issuer
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  when: cert_manager_use_letsencrypt
  block:
    - name: Create the route53 credentials secret
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: "{{ cert_manager_le_aws_creds_secret_name }}"
            namespace: cert-manager
          type: Opaque
          data:
            access-key-id: "{{ cert_manager_le_aws_access_key_id | b64encode }}"
            secret-access-key: "{{ cert_manager_le_aws_secret_access_key | b64encode }}"

    - name: Generate the Let's Encrypt ClusterIsuer
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: ClusterIssuer
          metadata:
            name: "{{ cert_manager_le_issuer_name }}"
          spec:
            acme:
              email: "{{ cert_manager_le_issuer_email }}"
              profile: tlsserver
              server: "{{ cert_manager_le_issuer_acme_server }}"
              privateKeySecretRef:
                name: "{{ cert_manager_le_issuer_acme_secret_name }}"
              solvers:
                - dns01:
                    cnameStrategy: Follow
                    route53:
                      region: "{{ cert_manager_le_aws_region }}"
                      accessKeyIDSecretRef:
                        name: "{{ cert_manager_le_aws_creds_secret_name }}"
                        key: access-key-id
                      secretAccessKeySecretRef:
                        name: "{{ cert_manager_le_aws_creds_secret_name }}"
                        key: secret-access-key
```

- [ ] **Step 3: Reduce issuers.yml to just the namespaced default-issuer**

Replace the entire contents of `roles/k8s_de_reqs/tasks/issuers.yml` with:

```yaml
---
- name: Apply self-signed issuers
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  block:
    - name: Apply default-issuer
      kubernetes.core.k8s:
        state: present
        namespace: "{{ ns }}"
        definition:
          apiVersion: cert-manager.io/v1
          kind: Issuer
          metadata:
            name: default-issuer
          spec:
            selfSigned: {}
```

- [ ] **Step 4: Wire the role into kubernetes.yml after cert-manager**

In `kubernetes.yml`, find:

```yaml
    - role: cert-manager
      tags: cert-manager

    - role: argo
      tags:
        - argo
        - de-reqs
```

Replace with:

```yaml
    - role: cert-manager
      tags: cert-manager

    # The cluster-scoped cert-manager issuers come right after cert-manager so
    # the certs requested later (Harbor, Traefik) can issue immediately. The
    # namespaced default-issuer stays in k8s_de_reqs (it needs the DE namespace).
    - role: cluster_issuers
      tags:
        - cert-issuers
        - de-reqs

    - role: argo
      tags:
        - argo
        - de-reqs
```

- [ ] **Step 5: Verify syntax and the issuer split**

Run (from `ansible/`):

```bash
ansible-playbook --syntax-check -i example/inventory kubernetes.yml 2>&1 | tail -3
grep -rn "default-cluster-issuer\|default-issuer\|cert_manager_le_issuer_name" roles/cluster_issuers roles/k8s_de_reqs/tasks/issuers.yml
```

Expected: syntax-check ends with `playbook: kubernetes.yml`, no ERROR. The grep shows `default-cluster-issuer` and the LE issuer only under `roles/cluster_issuers/`, and `default-issuer` only in `roles/k8s_de_reqs/tasks/issuers.yml`.

- [ ] **Step 6: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/roles/cluster_issuers ansible/roles/k8s_de_reqs/tasks/issuers.yml ansible/kubernetes.yml
git commit -m "$(cat <<'EOF'
CORE-2156: Move cluster cert-manager issuers ahead of Harbor

Split the cluster-scoped issuers (self-signed default-cluster-issuer and
the Let's Encrypt ClusterIssuer) out of k8s_de_reqs into a new
cluster_issuers role that runs right after cert-manager, so certs
requested by Harbor and Traefik issue immediately. The namespaced
default-issuer stays in k8s_de_reqs since it needs the DE namespace.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add Harbor TLS and ingress-class default variables

**Files:**
- Modify: `roles/common/defaults/main.yml`

**Interfaces:**
- Produces variables consumed by Tasks 3–5: `harbor_tls_cert_name` (`harbor-tls`), `harbor_tls_ca_name` (`harbor-selfsigned-ca`), `harbor_tls_issuer_name` (`harbor-ca-issuer`), `harbor_tls_ca_duration`, `harbor_tls_ca_renew_before`, `harbor_tls_cert_duration`, `harbor_tls_cert_renew_before`, `harbor_ingress_class_name` (`nginx`).

- [ ] **Step 1: Add the variables to the Harbor block**

In `roles/common/defaults/main.yml`, find the line:

```yaml
harbor_robot_secret: replace_me
```

Insert immediately after it:

```yaml

# Harbor exposure and TLS (ingress/gateway with cert-manager)
harbor_ingress_class_name: nginx
harbor_tls_cert_name: harbor-tls
harbor_tls_ca_name: harbor-selfsigned-ca
harbor_tls_issuer_name: harbor-ca-issuer
harbor_tls_ca_duration: 8766h
harbor_tls_ca_renew_before: 240h
harbor_tls_cert_duration: 2160h
harbor_tls_cert_renew_before: 240h
```

- [ ] **Step 2: Verify the file still parses and the vars are present**

Run (from `ansible/`):

```bash
ruby -ryaml -e 'YAML.safe_load(File.read("roles/common/defaults/main.yml")); puts "defaults: valid"'
grep -n "harbor_tls_\|harbor_ingress_class_name" roles/common/defaults/main.yml
```

Expected: `defaults: valid`, and the grep lists all eight new variables.

- [ ] **Step 3: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/roles/common/defaults/main.yml
git commit -m "$(cat <<'EOF'
CORE-2156: Add Harbor TLS and ingress-class defaults

Add harbor_ingress_class_name and the harbor_tls_* certificate variables
(mirroring de_tls_*) for the upcoming ingress/gateway exposure with
cert-manager-managed TLS.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the Harbor TLS certificate chain

**Files:**
- Create: `roles/harbor/tasks/certs.yml`
- Modify: `roles/harbor/tasks/main.yml`

**Interfaces:**
- Consumes: `harbor_tls_*` vars (Task 2); `default-cluster-issuer` / `cert_manager_le_issuer_name` ClusterIssuers (Task 1); `cert_manager_use_letsencrypt`, `harbor_namespace`, `harbor_fqdn` (existing).
- Produces: the `harbor-tls` Secret (named `{{ harbor_tls_cert_name }}`) in the `harbor` namespace, consumed by Tasks 4 (ingress-nginx) and 5 (Traefik gateway).

- [ ] **Step 1: Create the cert chain task file**

Create `roles/harbor/tasks/certs.yml`:

```yaml
---
- name: Configure cert-manager TLS for Harbor
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  block:
    - name: Define the self-signed CA certificate for Harbor
      when: not cert_manager_use_letsencrypt
      kubernetes.core.k8s:
        name: "{{ harbor_tls_ca_name }}"
        namespace: "{{ harbor_namespace }}"
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: Certificate
          metadata:
            name: "{{ harbor_tls_ca_name }}"
          spec:
            isCA: true
            commonName: "{{ harbor_tls_ca_name }}"
            secretName: "{{ harbor_tls_ca_name }}"
            duration: "{{ harbor_tls_ca_duration }}"
            renewBefore: "{{ harbor_tls_ca_renew_before }}"
            privateKey:
              algorithm: ECDSA
              size: 256
            issuerRef:
              name: default-cluster-issuer
              kind: ClusterIssuer
              group: cert-manager.io

    - name: Create the local certificate issuer for Harbor
      when: not cert_manager_use_letsencrypt
      kubernetes.core.k8s:
        name: "{{ harbor_tls_issuer_name }}"
        namespace: "{{ harbor_namespace }}"
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: Issuer
          metadata:
            name: "{{ harbor_tls_issuer_name }}"
          spec:
            ca:
              secretName: "{{ harbor_tls_ca_name }}"

    - name: Create the locally signed TLS certificate for Harbor
      when: not cert_manager_use_letsencrypt
      kubernetes.core.k8s:
        name: "{{ harbor_tls_cert_name }}"
        namespace: "{{ harbor_namespace }}"
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: Certificate
          metadata:
            name: "{{ harbor_tls_cert_name }}"
          spec:
            secretName: "{{ harbor_tls_cert_name }}"
            duration: "{{ harbor_tls_cert_duration }}"
            renewBefore: "{{ harbor_tls_cert_renew_before }}"
            issuerRef:
              name: "{{ harbor_tls_issuer_name }}"
              kind: Issuer
            commonName: "{{ harbor_fqdn }}"
            dnsNames:
              - localhost
              - "{{ harbor_fqdn }}"

    - name: Create the TLS certificate for Harbor using letsencrypt
      when: cert_manager_use_letsencrypt
      kubernetes.core.k8s:
        name: "{{ harbor_tls_cert_name }}"
        namespace: "{{ harbor_namespace }}"
        state: present
        definition:
          apiVersion: cert-manager.io/v1
          kind: Certificate
          metadata:
            name: "{{ harbor_tls_cert_name }}"
          spec:
            secretName: "{{ harbor_tls_cert_name }}"
            duration: "{{ harbor_tls_cert_duration }}"
            renewBefore: "{{ harbor_tls_cert_renew_before }}"
            issuerRef:
              name: "{{ cert_manager_le_issuer_name }}"
              kind: ClusterIssuer
            commonName: "{{ harbor_fqdn }}"
            dnsNames:
              - "{{ harbor_fqdn }}"
```

- [ ] **Step 2: Include the cert chain at the top of the Harbor role**

In `roles/harbor/tasks/main.yml`, the file currently starts with:

```yaml
---
- name: Add the harbor helm repository
```

Change the start to:

```yaml
---
- name: Configure the Harbor TLS certificate
  ansible.builtin.include_tasks: certs.yml

- name: Add the harbor helm repository
```

- [ ] **Step 3: Verify syntax**

Run (from `ansible/`):

```bash
ansible-playbook --syntax-check -i example/inventory kubernetes.yml 2>&1 | tail -3
```

Expected: ends with `playbook: kubernetes.yml`, no ERROR.

- [ ] **Step 4: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/roles/harbor/tasks/certs.yml ansible/roles/harbor/tasks/main.yml
git commit -m "$(cat <<'EOF'
CORE-2156: Add cert-manager TLS certificate chain for Harbor

Create harbor-tls via cert-manager, mirroring the DE service pattern: a
self-signed CA chain (harbor-selfsigned-ca -> harbor-ca-issuer ->
harbor-tls) by default, or issued directly from the letsencrypt
ClusterIssuer when cert_manager_use_letsencrypt is set.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Switch Harbor Helm exposure off NodePort

**Files:**
- Modify: `roles/harbor/tasks/main.yml`
- Modify: `roles/common/defaults/main.yml`

**Interfaces:**
- Consumes: `gateway_provider`, `harbor_tls_cert_name`, `harbor_ingress_class_name`, `harbor_fqdn`.
- Produces: for ingress-nginx, a Harbor-chart `Ingress` for `harbor_fqdn` using the `harbor-tls` secret; for Traefik, a Harbor `clusterIP` Service (named `harbor`, port `80`) that Task 5 routes to.

- [ ] **Step 1: Replace the expose block with a per-provider fact**

In `roles/harbor/tasks/main.yml`, find the helm-repository task and the start of the helm install, currently:

```yaml
- name: Add the harbor helm repository
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  kubernetes.core.helm_repository:
    name: harbor
    repo_url: "{{ harbor_repo }}"
    state: present

- name: Install the harbor helm chart
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  kubernetes.core.helm:
    name: harbor
    chart_ref: harbor/harbor
    create_namespace: true
    release_namespace: "{{ harbor_namespace }}"
    wait: true
    values:
      externalURL: "https://{{ harbor_fqdn }}"
      expose:
        type: nodePort
        tls:
          enabled: false
        nodePort:
          ports:
            http:
              nodePort: "{{ harbor_http_nodeport }}"
            https:
              nodePort: "{{ harbor_https_nodeport }}"
```

Replace that span with:

```yaml
- name: Add the harbor helm repository
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  kubernetes.core.helm_repository:
    name: harbor
    repo_url: "{{ harbor_repo }}"
    state: present

# Traefik fronts Harbor through a Gateway/HTTPRoute (see gateway.yml), so the
# chart only needs a clusterIP service and TLS is terminated at the gateway.
# ingress-nginx uses the chart's own Ingress, terminating TLS with the
# cert-manager-issued harbor-tls secret.
- name: Use Gateway API exposure for Harbor (Traefik)
  ansible.builtin.set_fact:
    harbor_expose:
      type: clusterIP
      tls:
        enabled: false
  when: gateway_provider == "traefik"

- name: Use Ingress exposure for Harbor (ingress-nginx)
  ansible.builtin.set_fact:
    harbor_expose:
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
  when: gateway_provider != "traefik"

- name: Install the harbor helm chart
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  kubernetes.core.helm:
    name: harbor
    chart_ref: harbor/harbor
    create_namespace: true
    release_namespace: "{{ harbor_namespace }}"
    wait: true
    values:
      externalURL: "https://{{ harbor_fqdn }}"
      expose: "{{ harbor_expose }}"
```

- [ ] **Step 2: Remove the now-unused NodePort defaults**

In `roles/common/defaults/main.yml`, delete these two lines:

```yaml
harbor_http_nodeport: 30002
harbor_https_nodeport: 30003
```

- [ ] **Step 3: Verify syntax and that the NodePort variables are gone**

Run (from `ansible/`):

```bash
ansible-playbook --syntax-check -i example/inventory kubernetes.yml 2>&1 | tail -3
grep -rn "harbor_http_nodeport\|harbor_https_nodeport" roles example || echo "no nodeport refs remain"
```

Expected: syntax-check ends with `playbook: kubernetes.yml`, no ERROR; the grep prints `no nodeport refs remain`.

- [ ] **Step 4: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/roles/harbor/tasks/main.yml ansible/roles/common/defaults/main.yml
git commit -m "$(cat <<'EOF'
CORE-2156: Expose Harbor via ingress/gateway instead of NodePort

Build the Harbor chart expose block per gateway_provider: clusterIP for
Traefik (routed via a Gateway in a later change) and the chart's own
Ingress for ingress-nginx, terminating TLS with the cert-manager-issued
harbor-tls secret. Drop the now-unused harbor_http_nodeport and
harbor_https_nodeport defaults.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add the Harbor Gateway and HTTPRoute for Traefik

**Files:**
- Create: `roles/harbor/tasks/gateway.yml`
- Modify: `roles/harbor/tasks/main.yml`

**Interfaces:**
- Consumes: `harbor_namespace`, `gateway_class_name` (default `traefik`), `harbor_fqdn`, `harbor_tls_cert_name`, the `harbor` clusterIP Service from Task 4, `gateway_provider`.
- Produces: a `harbor` Gateway and HTTPRoute exposing `harbor_fqdn` over HTTPS via Traefik.

- [ ] **Step 1: Create the gateway/route task file**

Create `roles/harbor/tasks/gateway.yml`:

```yaml
---
- name: Configure the Gateway API resources for Harbor
  delegate_to: localhost
  environment:
    KUBECONFIG: "{{ lookup('env', 'KUBECONFIG') }}"
  block:
    - name: Define the gateway for Harbor
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: gateway.networking.k8s.io/v1
          kind: Gateway
          metadata:
            name: harbor
            namespace: "{{ harbor_namespace }}"
          spec:
            gatewayClassName: "{{ gateway_class_name }}"
            listeners:
              - hostname: "{{ harbor_fqdn }}"
                name: harbor-http
                port: 8000
                protocol: HTTP
              - hostname: "{{ harbor_fqdn }}"
                name: harbor-https
                port: 8443
                protocol: HTTPS
                tls:
                  certificateRefs:
                    - kind: Secret
                      group: ""
                      name: "{{ harbor_tls_cert_name }}"

    - name: Define the HTTPRoute for Harbor
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: gateway.networking.k8s.io/v1
          kind: HTTPRoute
          metadata:
            name: harbor
            namespace: "{{ harbor_namespace }}"
          spec:
            hostnames:
              - "{{ harbor_fqdn }}"
            parentRefs:
              - name: harbor
            rules:
              - backendRefs:
                  - name: harbor
                    port: 80
```

- [ ] **Step 2: Include the gateway tasks at the end of the Harbor role (Traefik only)**

In `roles/harbor/tasks/main.yml`, after the `Install the harbor helm chart` task (the last task in the file), append:

```yaml

- name: Configure the Harbor gateway route
  ansible.builtin.include_tasks: gateway.yml
  when: gateway_provider == "traefik"
```

- [ ] **Step 3: Verify syntax**

Run (from `ansible/`):

```bash
ansible-playbook --syntax-check -i example/inventory kubernetes.yml 2>&1 | tail -3
```

Expected: ends with `playbook: kubernetes.yml`, no ERROR.

- [ ] **Step 4: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/roles/harbor/tasks/gateway.yml ansible/roles/harbor/tasks/main.yml
git commit -m "$(cat <<'EOF'
CORE-2156: Route Harbor through a Traefik Gateway/HTTPRoute

When gateway_provider is traefik, create a harbor Gateway (HTTP + HTTPS
listeners, TLS from the harbor-tls secret) and an HTTPRoute to the Harbor
clusterIP service, matching how DE/portal/vice are exposed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update the example group_vars documentation

**Files:**
- Modify: `example/inventory/group_vars/all.yaml`

**Interfaces:**
- Consumes: nothing at runtime (all lines are comments). Documents Task 1–5 behavior.

- [ ] **Step 1: Rewrite the Harbor section intro and variables**

In `example/inventory/group_vars/all.yaml`, find the Harbor section intro block that begins:

```
# Installed by the `harbor` role (`kubernetes.yml --tags harbor`). It
# deploys the Harbor container registry via its Helm chart, exposed on
# NodePorts and backed by the external PostgreSQL databases created in
# Phase 2 (see the "Harbor databases" subsection there).
```

Replace just the sentence `exposed on\n# NodePorts and` so the paragraph reads:

```
# Installed by the `harbor` role (`kubernetes.yml --tags harbor`). It
# deploys the Harbor container registry via its Helm chart, exposed
# through the active gateway/ingress controller (Traefik via the Gateway
# API, otherwise an ingress-nginx Ingress) with cert-manager-managed TLS,
# and backed by the external PostgreSQL databases created in Phase 2 (see
# the "Harbor databases" subsection there).
```

- [ ] **Step 2: Replace the NodePort variable docs with exposure/TLS docs**

In the same Harbor section, find:

```
# NodePort Harbor exposes for plain HTTP. The chart's own TLS is
# disabled — HTTPS is terminated upstream.
# Default: 30002
# harbor_http_nodeport: 30002

# NodePort Harbor exposes for HTTPS.
# Default: 30003
# harbor_https_nodeport: 30003
# =====================================================================
```

Replace with:

```
# Ingress class used when gateway_provider is not "traefik" (the
# ingress-nginx path). Ignored under Traefik, which fronts Harbor with a
# Gateway/HTTPRoute instead.
# Default: nginx
# harbor_ingress_class_name: nginx

# cert-manager TLS for Harbor. In the default self-signed mode a CA chain
# is created (harbor-selfsigned-ca -> harbor-ca-issuer -> harbor-tls); when
# cert_manager_use_letsencrypt is true (Phase 6) harbor-tls is issued
# directly from the letsencrypt ClusterIssuer. These names and lifetimes
# mirror the DE service certificates.
# Default: harbor-tls
# harbor_tls_cert_name: harbor-tls

# Name of the self-signed CA Certificate/Issuer secret (self-signed mode).
# Default: harbor-selfsigned-ca
# harbor_tls_ca_name: harbor-selfsigned-ca

# Name of the CA-backed Issuer that signs harbor-tls (self-signed mode).
# Default: harbor-ca-issuer
# harbor_tls_issuer_name: harbor-ca-issuer

# Validity period of the self-signed CA certificate.
# Default: 8766h
# harbor_tls_ca_duration: 8766h

# How long before CA expiry cert-manager renews it.
# Default: 240h
# harbor_tls_ca_renew_before: 240h

# Validity period of the harbor-tls certificate.
# Default: 2160h
# harbor_tls_cert_duration: 2160h

# How long before TLS expiry cert-manager renews it.
# Default: 240h
# harbor_tls_cert_renew_before: 240h
# =====================================================================
```

- [ ] **Step 3: Note the cluster-issuer move in the Phase 6 / Phase 7 docs**

In the same file, find the Phase 7 intro sentence:

```
# Run this phase after cert-manager (Phase 6) — the issuers it creates
# depend on the cert-manager CRDs. The cert-manager issuer variables
# (`cert_manager_*`) are applied during this pass but are documented
# under Phase 6.
```

Replace with:

```
# Run this phase after cert-manager (Phase 6). The cluster-scoped issuers
# (default-cluster-issuer and the Let's Encrypt ClusterIssuer) are created
# earlier by the `cluster_issuers` role so certs can issue before Harbor;
# this pass only creates the namespaced `default-issuer`. The cert-manager
# issuer variables (`cert_manager_*`) are documented under Phase 6.
```

- [ ] **Step 4: Verify the file is still a no-op and headers are intact**

Run (from `ansible/`):

```bash
ruby -ryaml -e 'p YAML.safe_load(File.read("example/inventory/group_vars/all.yaml"))'
grep -n "harbor_ingress_class_name\|harbor_tls_\|harbor_http_nodeport\|harbor_https_nodeport" example/inventory/group_vars/all.yaml || true
```

Expected: prints `nil`; the grep lists the new `harbor_ingress_class_name` / `harbor_tls_*` comment lines and shows no `harbor_http_nodeport` / `harbor_https_nodeport` lines remaining.

- [ ] **Step 5: Commit**

```bash
cd /Users/sarahr/src/de/deployments
git add ansible/example/inventory/group_vars/all.yaml
git commit -m "$(cat <<'EOF'
CORE-2156: Document Harbor ingress/gateway TLS in example group_vars

Update the Harbor section for the new ingress/gateway exposure and
cert-manager TLS variables (drop the NodePort vars), and note that the
cluster-scoped issuers now come from the cluster_issuers role before
Harbor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cluster verification (manual, requires a live cluster)

This task has no code; it validates the feature end-to-end. Run against a test cluster with `KUBECONFIG` set.

- [ ] **Step 1: Confirm the harbor-tls secret issued**

```bash
kubectl -n harbor get certificate,secret | grep harbor-tls
```

Expected: a `Certificate/harbor-tls` with `READY=True` and a `Secret/harbor-tls` of type `kubernetes.io/tls`. In self-signed mode also expect `harbor-selfsigned-ca`.

- [ ] **Step 2: Confirm the clusterIP service name/port assumed by the HTTPRoute (Traefik)**

```bash
kubectl -n harbor get svc harbor -o jsonpath='{.spec.type} {.spec.ports[*].port}{"\n"}'
```

Expected: `ClusterIP 80`. If the service name or port differs, update `roles/harbor/tasks/gateway.yml` Step 1 `backendRefs` accordingly and re-run, then amend Task 5's commit.

- [ ] **Step 3: Confirm routing resources exist for the active provider**

Traefik:
```bash
kubectl -n harbor get gateway harbor httproute harbor
```
Expected: the Gateway shows `PROGRAMMED=True` and the HTTPRoute is attached.

ingress-nginx:
```bash
kubectl -n harbor get ingress
```
Expected: a Harbor Ingress for `harbor_fqdn` referencing the `harbor-tls` secret in its `tls` block.

- [ ] **Step 4: Confirm Harbor serves over HTTPS and accepts a login**

```bash
curl -sk "https://$(printf %s harbor.cyverse.org)/api/v2.0/systeminfo" -o /dev/null -w '%{http_code}\n'
podman login harbor.cyverse.org   # or: docker login harbor.cyverse.org
```

Expected: HTTP `200` from the API, and a successful login. (Substitute the deployment's real `harbor_fqdn` if not the default.)

---

## Self-Review

- **Spec coverage:** §1 cluster_issuers → Task 1. §2 cert chain → Task 3 (+vars Task 2). §3 expose change → Task 4. §4 Gateway/HTTPRoute → Task 5. §5 wiring/cleanup → Tasks 3–5 (includes) + Task 4 (nodeport removal). §6 variables → Task 2 (add) + Task 4 (remove). §7 docs → Task 6. Verification → Task 7. All spec sections covered.
- **Placeholder scan:** No TBD/TODO; the one spec "to confirm" item (clusterIP service name/port) is an explicit verification step (Task 7 Step 2) with a concrete assumed value and a remediation instruction. No "add error handling"-style vagueness.
- **Type/name consistency:** `harbor_tls_cert_name`/`_ca_name`/`_issuer_name` and the four duration vars are defined in Task 2 and used verbatim in Tasks 3–6. `harbor-tls` secret produced in Task 3 is referenced in Task 4 (ingress `secret.secretName`) and Task 5 (`certificateRefs`). `gateway_class_name`, `gateway_provider`, `cert_manager_use_letsencrypt`, `cert_manager_le_issuer_name` are pre-existing. The HTTPRoute `backendRefs.name: harbor` / `port: 80` matches the clusterIP service assumption flagged in Task 7.
