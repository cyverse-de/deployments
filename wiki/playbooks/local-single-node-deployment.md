---
type: Runbook
title: Local Single-Node Deployment
description: How to stand up a full DE from scratch on a freshly installed single-node k0s cluster with local.yml, using a host PostgreSQL, sslip.io hostnames on a pinned Traefik ClusterIP, a locally trusted CA, an in-cluster RabbitMQ, and a reused QA iRODS zone.
resource: /ansible/local.yml
tags: [local, development, k0s, single-node, ansible, sslip.io, dns]
timestamp: 2026-07-29T00:00:00Z
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

- A machine with `k0s` installed and PostgreSQL running on the host.
- Outbound DNS, since the hostnames resolve through `sslip.io`.
- `ansible`, `kubectl` >= 1.31 (or `kustomize` >= 5.2), `helm` >= 3.16,
  `skaffold`, `golang-migrate` >= 4.18, `psql` >= 14, `gpg` >= 2.1,
  `openssl` >= 1.1.1, and `slappasswd`.
- A pull robot account on the image registry.
- The private `local-deployment` inventory repo.

## Host preparation

Done once, outside Ansible. Steps 2 and 5 need no `sudo`; the rest do. The default
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

The DE hostnames need no entry — see Hostnames and DNS below.

**5. Check the host PostgreSQL has no leftover DE databases** (no sudo).
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

**6. Let PostgreSQL accept connections from pods** (sudo). `local_db_endpoint` points
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

## Hostnames and DNS

Every DE hostname derives from one address in the inventory:

```yaml
local_gateway_ip: 10.96.0.100
local_gateway_dns: "{{ local_gateway_ip | replace('.', '-') }}.sslip.io"
de_hostname: "de.{{ local_gateway_dns }}"
```

`sslip.io` answers any name ending in a dashed IP with that address, including
multi-label prefixes — which is what the per-analysis VICE hostnames need and
what `/etc/hosts` fundamentally cannot provide. Nothing has to be configured on
the host or in the cluster.

The address is **Traefik's ClusterIP, pinned** via `traefik_cluster_ip`. That
matters for two reasons. It is reachable both from pods and from the host, so
one DNS answer serves the browser and the cluster and no split-horizon DNS or
edge proxy is needed — and it answers on 443, so no NodePort appears in any
URL. Pinning it keeps the address stable, since the hostnames encode it.
ClusterIP is immutable, so changing it means deleting the Traefik Service and
re-running the role.

**Why not `*.localhost`.** It cannot work, for a reason no amount of DNS
configuration fixes: musl libc implements RFC 6761 by resolving `*.localhost`
to `127.0.0.1` **without consulting DNS at all**, so those names are unusable
from any Alpine-based pod. And services genuinely do resolve DE hostnames
in-cluster — vice-operator looks up `keycloak_hostname` both to build a VICE
egress exception and to run OIDC discovery, and dies if it cannot. A CoreDNS
`hosts` entry fixes Go services and still leaves musl ones broken. It is also
a resource k0s owns (`k0s.k0sproject.io/stack: coredns`), so it is re-applied
on restart or upgrade.

Changing the address later is a one-line inventory edit, followed by re-running
`traefik` (after deleting the Service), `ingress`, `configure-services`,
`keycloak` and `deploy-all-services` — the hostnames appear in certificates,
Keycloak redirect URIs and every service's config.

## TLS

Let's Encrypt cannot validate `.localhost` names, so the deployment issues from
a locally trusted root instead. Setting `cluster_issuer_default_type: ca` makes
[cert-manager](/infrastructure/cert-manager.md)'s `default-cluster-issuer` a CA
issuer backed by a keypair on disk, and the ordinary
`cert_manager_provider: selfsigned` chain then issues DE, portal, VICE, and
[Keycloak](/infrastructure/keycloak.md) certificates beneath it. No other role
changes.

**The root must permit an intermediate.** The `selfsigned` chain is
root → per-endpoint CA (`de-selfsigned-ca`, `kc-selfsigned-ca`, …) → leaf, so
the root needs `pathlen` of at least 1. This rules out a **mkcert** root, which
is issued with `CA:TRUE, pathlen:0` and cannot sign an intermediate. Using one
anyway produces certificates that look correct — every individual certificate
is valid and cert-manager reports `Ready` — but every client rejects the chain
with `path length constraint exceeded`. A smoke test that issues a leaf
directly from `default-cluster-issuer` passes, because it has no intermediate;
it does not exercise the shape the endpoints actually use.

Generate a root that permits one:

```bash
mkdir -p ~/.local/share/de-local-ca && cd ~/.local/share/de-local-ca
cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = CyVerse DE local development
CN = CyVerse DE local development CA
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout rootCA-key.pem -out rootCA.pem -config ca.cnf
chmod 600 rootCA-key.pem
```

Then trust it (sudo), which covers both the system store and the NSS store
Firefox and Chrome read through p11-kit:

```bash
sudo trust anchor --store ~/.local/share/de-local-ca/rootCA.pem
```

Verify with `curl https://de.localhost/` — no `-k`. A `path length constraint
exceeded` means the root has the wrong constraint; `unable to get local issuer
certificate` means it is not trusted yet.

The CA private key ends up in a Secret in the `cert-manager` namespace, so
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
| `cert-issuers` | The local CA Secret and `default-cluster-issuer` |
| `traefik` | Gateway API CRDs, Traefik, its default certificate |
| `argo` | Argo Workflows and argo-events |
| `setup-databases` | The DE, notifications, metadata, grouper, qms, and portal databases, and their migrations |
| `de-reqs` | Namespaces, the timezone ConfigMap, local-exim, the image-pull secret, the database Service, RabbitMQ |
| `openldap-docker` | In-cluster [OpenLDAP](/infrastructure/ldap.md) |
| `keycloak` | Keycloak and its Gateway, then the realm, clients and LDAP federation |
| `keycloak-config` | The realm configuration on its own, against a Keycloak that is already up |
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

**Keycloak's realm has to be configured before anything can authenticate.**
`keycloak_install` creates the admin user and nothing else — no realm, no
clients, no user federation. The `keycloak_config` role fills that gap and runs
under the same `keycloak` tag, so a normal bring-up covers it. Running only
`--tags keycloak-config` reconfigures an existing Keycloak.

The claim that matters is `entitlement`: `admin_attribute` and `admin_groups`
are checked against it, and it takes *two* mappers to produce — a
`group-ldap-mapper` on the federation provider to bring group membership into
Keycloak, and a `Group Membership` mapper on the `profile` client scope to put
it in the token. With only the first, users authenticate and nobody is an
admin. Verify with a token rather than by reading the UI:

```bash
curl -s -d client_id=<de client> -d client_secret=<secret> \
     -d username=<user> -d password=<pw> -d grant_type=password \
     -d 'scope=openid profile' \
     https://keycloak.<domain>/auth/realms/<realm>/protocol/openid-connect/token
```

and decode the `access_token` payload — `entitlement` should list the user's
groups.

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

**Hostname resolution depends on a third party.** `sslip.io` is a public DNS
service, so with no outbound DNS the DE is unreachable — including from the
browser. The fixed names can be papered over with `/etc/hosts` pointing at
`local_gateway_ip`, but the VICE wildcard cannot, so analyses stop working
offline. If that matters, run a local wildcard resolver (dnsmasq) instead;
sslip.io is also self-hostable, which is why it is preferred over the
alternatives.

**Pods need the private CA for any server-side TLS to a DE hostname.**
vice-operator is the case that surfaced it, via
`vice_operator_ca_bundle_configmap`. A service added later that calls a DE
endpoint over HTTPS from inside the cluster will need the same treatment, and
will fail with `certificate signed by unknown authority` until it gets it.

**Analyses write into a shared zone.** `irods_user` is a rodsadmin proxy
account, so this deployment has write access to every user's home collection in
the reused zone, and both deployments push ACLs and AVUs onto the same
collections. `de_default_output_folder` is set to a distinct name to keep
outputs out of the folders the other environments use, but that is containment,
not isolation.

## Manual steps, and which are worth automating

Everything below is done by hand today. The table records why, so the list can
be worked down rather than rediscovered. "Blocker" means the deployment cannot
proceed without it.

| # | Step | Needs | Blocker | Automation notes |
| --- | --- | --- | --- | --- |
| 1 | `k0s install controller --single` | sudo | yes | Reasonable to leave manual — it is the one step that defines the machine. A `k0sctl.yaml` against localhost would work but adds SSH-to-self. |
| 2 | Write the kubeconfig | sudo (read) | yes | Could fold into step 1 as a documented one-liner. Low value alone. |
| 3 | Kubelet plugin directories for the iRODS CSI driver | sudo | yes | `kubernetes.yml` does this in a `become: true` play over the worker group. A local variant would need one privileged play, which is the only thing forcing sudo into the Ansible run — worth weighing against keeping `local.yml` sudo-free. |
| 4 | `/etc/hosts` entry for the database name | sudo | yes | Avoidable: give the `dbms` inventory host an `ansible_host` of `127.0.0.1` and the pods a Service name, instead of one name that has to resolve in both places. Would remove a sudo step and a class of confusion. **Best automation candidate.** |
| 5 | PostgreSQL `listen_addresses` + `pg_hba.conf` | sudo | yes | Deliberately manual: the workstation's PostgreSQL is not the deployment's to own. Could be offered as an opt-in play guarded by a variable, defaulting off. |
| — | ~~Edge proxy TCP passthrough~~ | — | — | **Eliminated.** The pinned Traefik ClusterIP answers on 443 from the host, so no proxy sits in front of the cluster and no NodePort appears in a URL. |
| 7 | Generate and trust the local root CA | sudo (trust only) | yes | Generation is scriptable today (see the TLS section); only `trust anchor` needs sudo. Fold the openssl half into `scripts/generate-secrets.sh` or a sibling script. **Good automation candidate.** |
| — | ~~Cluster DNS for the DE hostnames~~ | — | — | **Never needed.** sslip.io resolves from both the host and the cluster, so there is no CoreDNS edit to maintain — which also avoids fighting a resource k0s owns. |
| 8 | Check for leftover DE databases and roles | no | yes, if dirty | Could become a pre-flight assertion in `postgresql_init` that fails with a clear message instead of `Changing ICU_LOCALE is not supported`. **Good automation candidate.** |
| 9 | ~~Keycloak realm, clients, LDAP federation, group mapper~~ | — | — | **Automated** by the `keycloak_config` role (tag `keycloak-config`). Realm, 5 realm roles, required actions, LDAP federation with the standard plus DE-specific mappers, the `profile` scope claim mappers, all 8 clients, and the `vice-api` service-account role. |
| 10 | Seed the portal `account_*` reference tables | no | yes, for registration | Pure data seeding; belongs in `postgresql_init/tasks/portal.yml` next to the GRID import that already runs there. **Good automation candidate.** |

# Citations

* `ansible/local.yml`
* `ansible/roles/local_node_prep/`
* `ansible/roles/local_db_endpoint/`
* `ansible/roles/rabbitmq_k8s/`
* `ansible/roles/cluster_issuers/tasks/main.yml`
* `ansible/scripts/generate-secrets.sh`
* [mkcert](https://github.com/FiloSottile/mkcert)
