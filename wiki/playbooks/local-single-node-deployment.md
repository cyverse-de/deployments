---
type: Runbook
title: Local Single-Node Deployment
description: How to stand up a full DE from scratch on a freshly installed single-node k0s cluster with local.yml, using a host PostgreSQL, an mkcert-backed CA, an in-cluster RabbitMQ, and a reused QA iRODS zone.
resource: /ansible/local.yml
tags: [local, development, k0s, single-node, ansible, mkcert]
timestamp: 2026-07-28T00:00:00Z
---

`local.yml` stands up a complete Discovery Environment — every service,
sonora, the user portal, VICE, and Argo batch — on a single Kubernetes node on
a workstation. It exists because [kubernetes.yml](/playbooks/full-deployment.md)
cannot be reduced to this shape by turning things off: several of its plays
build the cluster, reconfigure the nodes over SSH, or need `sudo`, and one of
them wires in `k0sctl` with no conditional.

## What it does and doesn't do

`local.yml` assumes a Kubernetes node **already exists** and only talks to its
API server — but it assumes nothing is deployed on it. Point it at a freshly
installed single node and it brings up storage, cert-manager, the gateway, the
broker, and the whole DE. Relative to `kubernetes.yml` it drops:

| Dropped | Why |
| --- | --- |
| `k8s_cluster` | One node is installed directly with `k0s`, not through `k0sctl`. |
| `k8s_nodes`, `k8s_firewalld` | They swap off, rewrite `fstab`, set SELinux permissive, and reboot. |
| `postgresql`, `postgresql_access` | The workstation's PostgreSQL config is not ours to rewrite. |
| `nvidia_drivers`, `nvidia_container_toolkit` | Host package management. |
| `haproxy`, `ui_haproxy` | The edge proxy is a hand-managed systemd unit. |
| `longhorn` | Storage is [OpenEBS](/infrastructure/openebs.md); one node has nothing to replicate to. |
| `harbor` | Images pull from an external registry. |
| `ingress_nginx` | Only [Harbor](/infrastructure/harbor.md) uses it. |
| `kubernetes_node_feature_discovery` | Installs a device plugin that crashloops without the container toolkit. |

and adds three roles that stand in for infrastructure living outside the
cluster in other environments:

- **`local_node_prep`** — applies the `analysis`/`vice`/`batch`/`gpu` labels
  that scheduling and the image cache key off of, and strips the taints that
  carry them. On one node those taints would leave every DE service `Pending`:
  no service manifest carries a toleration.
- **`local_db_endpoint`** — publishes the host's PostgreSQL as a selector-less
  Service plus EndpointSlice, so pods can reach it by a stable cluster DNS
  name.
- **`rabbitmq_k8s`** — a single-replica [RabbitMQ](/infrastructure/rabbitmq.md)
  in the cluster, because the `rabbitmq` role installs a broker on a host over
  SSH.

## Prerequisites

- A machine with `k0s` installed, PostgreSQL running on the host, and
  `mkcert`.
- `ansible`, `kubectl` >= 1.31 (or `kustomize` >= 5.2), `helm` >= 3.16,
  `skaffold`, `golang-migrate` >= 4.18, `psql` >= 14, `gpg` >= 2.1,
  `openssl` >= 1.1.1, and `slappasswd`.
- A pull robot account on the image registry.
- The private `local-deployment` inventory repo.

## Host preparation

Done once, outside Ansible. Every step except 2 needs `sudo`. The default
StorageClass is not among them: the `openebs` role sets it when
`openebs_default_storage_class` is true, which the local inventory does.

**1. Bring up the k0s node** (sudo). `--single` gives a combined
controller/worker with no taint, which is what a one-machine deployment wants
— `--enable-worker` would add `node-role.kubernetes.io/master:NoSchedule`
instead, and nothing would schedule until the `node-prep` tag stripped it:

```bash
sudo k0s install controller --single
sudo k0s start
sudo k0s status          # wait for "Kube-api probing successful: true"
```

This is the plain `k0s` installer rather than `k0sctl`, which drives node
installs over SSH and earns its keep on multi-node clusters. k0s defaults to a
pod CIDR of `10.244.0.0/16` and a service CIDR of `10.96.0.0/12`; the inventory
has to agree with whatever this node actually uses, because those values become
local-exim's relay allowlist.

**2. Write a kubeconfig** (no sudo, apart from reading k0s's admin config):

```bash
sudo k0s kubeconfig admin > ~/.kube/local-admin.conf
chmod 600 ~/.kube/local-admin.conf
export KUBECONFIG=~/.kube/local-admin.conf
kubectl get nodes        # the node should reach Ready within a minute or two
```

If the node's address later changes, k0s keeps the one it was installed with,
so fix the `server:` line rather than reinstalling.

**3. Create the iRODS CSI driver's kubelet directories** (sudo), which are
otherwise created by a play that needs root on each worker:

```bash
sudo mkdir -p /var/lib/k0s/kubelet/plugins/irods.csi.cyverse.org \
              /var/lib/k0s/kubelet/plugins_registry
```

**4. Add the database name to `/etc/hosts`** (sudo). `groups['dbms'][0]` is used
verbatim both by the Ansible PostgreSQL modules on this machine and by the DB
URIs rendered into pod configs, so the one name has to resolve in both places:

```
127.0.0.1  db.de.svc.cluster.local
```

`de.localhost`, `user.localhost`, `keycloak.localhost` and every
`*.vice.localhost` VICE hostname need no entry — systemd-resolved synthesizes
all `.localhost` names to the loopback address. Confirm with
`getent hosts foo.vice.localhost`.

**5a. Check the host PostgreSQL has no leftover DE databases** (no sudo).
`postgresql_init` creates the databases with `locale_provider: icu`, and a
database's ICU locale cannot be changed after creation — so if `de`,
`notifications`, `metadata`, `grouper`, `qms`, `portal` or `keycloak` already
exist from earlier work and were created without ICU, `setup-databases` fails
with `Changing ICU_LOCALE is not supported`. It is easy to misread as a
permissions problem. Check, and drop what is stale (dump first if unsure —
these are on a workstation, not managed by the deployment):

```bash
psql -h db.de.svc.cluster.local -U postgres \
  -Atc "select datname from pg_database where datname not like 'template%'"
```

Check the **roles** too, which outlive the databases they own:

```bash
psql -h db.de.svc.cluster.local -U postgres \
  -Atc "select rolname, rolcanlogin from pg_authid where rolname in
        ('de','keycloak','portal','GrouperSystem')"
```

A role that already exists without `LOGIN` is the nastier version of this:
`postgresql_init` reconciles only the attributes it names, so it sets the
password correctly and the service still cannot connect. Keycloak surfaces it
as a crashloop on `password authentication failed for user "keycloak"`, which
points nowhere near the cause. `alter role <name> login` fixes it.

**5. Let PostgreSQL accept connections from pods** (sudo). `local_db_endpoint` points
the Service at the CNI bridge address (the first host address of the node's
podCIDR), which is node-local — unlike the node's registered `InternalIP`,
which may belong to an overlay interface and would expose the database well
beyond the machine. In `postgresql.conf`:

```
listen_addresses = '127.0.0.1,10.244.0.1'
```

and in `pg_hba.conf`, matching the cluster's pod CIDR:

```
host  all  all  10.244.0.0/16  scram-sha-256
```

Then restart PostgreSQL.

**6. Put the edge proxy in TCP passthrough** (sudo). TLS has to terminate at
[Traefik](/infrastructure/ingress.md) rather than at the proxy, so that Traefik
sees SNI and can route the per-analysis VICE hostnames:

```
defaults
    log     global
    timeout connect 5s

frontend http_in
    mode http
    option httplog
    timeout client 30s
    bind 127.0.0.1:80
    redirect scheme https code 301

frontend https_in
    mode tcp
    option tcplog
    timeout client 24h
    bind 127.0.0.1:443
    default_backend k8s_gateway

backend k8s_gateway
    mode tcp
    timeout server 24h
    server local 127.0.0.1:31383 check inter 5000
```

The backend port is `traefik_https_port`. The 24h timeouts match the ones the
Traefik role sets on its entrypoints and the ones the DE's HTTPRoutes set on
their backends: VICE sessions idle for long stretches, and a shorter timeout
here drops them with nothing in any log to explain it. Reload the proxy.

## TLS

Let's Encrypt cannot validate `.localhost` names, so the deployment reuses the
workstation's mkcert root instead. Setting `cluster_issuer_default_type: ca`
makes [cert-manager](/infrastructure/cert-manager.md)'s
`default-cluster-issuer` a CA issuer backed by that keypair, and the ordinary
`cert_manager_provider: selfsigned` chain then issues DE, portal, VICE, and
[Keycloak](/infrastructure/keycloak.md) certificates that chain to a root the
browser already trusts. No other role changes.

Run `mkcert -install` once if the root is not already in the trust store. Note
that the CA private key ends up in a Secret in the `cert-manager` namespace, so
anything able to read secrets there can mint certificates this machine trusts —
fine for a workstation, not a pattern to copy onto a shared cluster.

## Bring-up sequence

```bash
export INVENTORY=/path/to/local-deployment/inventory
export KUBECONFIG=~/.kube/local-admin.conf
cd /path/to/deployments/ansible
```

Generate the inventory's secrets first — terrain will not start without them:

```bash
./scripts/generate-secrets.sh "$INVENTORY"
```

Then, in order (`ansible-playbook -i "$INVENTORY" local.yml --tags ...`):

| Tags | Brings up |
| --- | --- |
| `node-prep` | Node labels; removes the taints that repel DE services |
| `openebs` | The storage provider and the default StorageClass |
| `cert-manager` | cert-manager and its CRDs |
| `cert-issuers` | The mkcert CA Secret and `default-cluster-issuer` |
| `traefik` | Gateway API CRDs, Traefik, its default certificate |
| `argo` | Argo Workflows and argo-events |
| `setup-databases` | The DE, notifications, metadata, grouper, qms, and portal databases, and their migrations |
| `de-reqs` | Namespaces, the timezone ConfigMap, local-exim, the image-pull secret, the database Service, RabbitMQ |
| `openldap-docker` | In-cluster [OpenLDAP](/infrastructure/ldap.md) |
| `keycloak` | Keycloak and its Gateway |
| `configure-services,secrets` | The shared `configs` Secret and the GPG/signing/accepted-key Secrets |
| `ingress` | Endpoint certificates, Gateways, and HTTPRoutes |
| `networking` | The kifshare, terrain, and job-status-listener NodePorts |
| `opensearch` | Single-node [OpenSearch](/infrastructure/opensearch.md) |
| `grouper` | [Grouper](/infrastructure/grouper.md) WS and loader |
| `irods-csi-driver` | The [iRODS](/infrastructure/irods.md) CSI driver |
| `deploy-all-services` | Every DE service |
| `cronjobs` | The scheduled jobs |

Then `argo_resources.yml`, the portal reference-table seeding described below,
and `bootstrap_portal_admin.yml`.

`image-cache` is deliberately opt-in: it pre-pulls every image in
`vice_image_cache` onto the node's disk.

Verify the CA issuer with a throwaway Certificate before going past
`cert-issuers`, and check that `curl https://dashboard.localhost` succeeds
without `-k` after `traefik`. Both failures are much cheaper to find there than
after forty services are running.

## Ordering hazards

**The `configs` Secret must exist before any service deploys.**
`service_configurations` is its only producer and every service `envFrom`s it;
deploy earlier and the pods sit in `CreateContainerConfigError`.

**Keycloak's realm and clients are created by hand.** `keycloak_install`
creates the admin user and nothing else — no realm, no clients, no user
federation. Before terrain or sonora can authenticate anyone, the realm named
by `keycloak_realm_name` needs each client from the inventory
(`keycloak_client_id`, `keycloak_vice_client_id`, `keycloak_admin_client_id`,
`formation_keycloak_client_id`, `portal_keycloak_client`, and the three
vice-operator clients) with matching secrets, an LDAP user federation provider
pointing at `ldap_uri`, and a group mapper producing the `entitlement` claim
that `admin_attribute` and `admin_groups` expect. Skip this and terrain starts
but every authenticated call returns 401.

**LDAP has to be seeded before Grouper and the portal.** Grouper binds as
`ldap_cn` + `ldap_base_dn` and portal-conductor binds as the rootdn. The seed
LDIF only loads against a fresh volume, so a wrong `ldap_dn_suffix` means
deleting the StatefulSet's PVC and starting over.

**The portal's `account_*` reference tables are empty on a fresh database.**
`postgresql_init` populates only `account_institution_grid`, but both
`bootstrap_portal_admin.yml` and self-registration insert an `account_user` row
using subselects for a `Not Provided` row in `account_awarechannel`,
`account_ethnicity`, `account_fundingagency`, `account_gender`,
`account_occupation`, `account_region`, `account_country`, and
`account_researcharea`. Without those rows the subselects return NULL and the
insert dies on a NOT NULL constraint — self-registration returns a 500. Seed
them before the bootstrap step.

## Consequences of the shortcuts

**Data search stays empty.** `irods_amqp_host` points at the in-cluster broker
rather than the one the reused iRODS zone publishes to, because consuming that
vhost would take change events away from the other deployment's consumers.
`dewey`, `info-typer`, and `infosquito2` run and idle, and nothing populates the
index.

**Analyses write into a shared zone.** `irods_user` is a rodsadmin proxy
account, so this deployment has write access to every user's home collection in
the reused zone, and both deployments push ACLs and AVUs onto the same
collections. `de_default_output_folder` is set to a distinct name to keep
outputs out of the folders the other environments use, but that is containment,
not isolation.

# Citations

* `ansible/local.yml`
* `ansible/roles/local_node_prep/`
* `ansible/roles/local_db_endpoint/`
* `ansible/roles/rabbitmq_k8s/`
* `ansible/roles/cluster_issuers/tasks/main.yml`
* `ansible/scripts/generate-secrets.sh`
* [mkcert](https://github.com/FiloSottile/mkcert)
