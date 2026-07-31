---
type: Runbook
title: Local Single-Node Deployment
description: How to stand up a full DE from scratch on a freshly installed single-node k0s cluster with local.yml, using an in-cluster PostgreSQL and RabbitMQ, sslip.io hostnames on a pinned Traefik ClusterIP, a locally trusted CA, and a reused QA iRODS zone.
resource: /ansible/local.yml
tags: [local, development, k0s, single-node, ansible, sslip.io, dns, cloudnativepg]
timestamp: 2026-07-31T00:00:00Z
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
| `postgresql`, `postgresql_access` | The database runs in the cluster, or on a workstation whose config is not ours to rewrite. |
| `nvidia_drivers`, `nvidia_container_toolkit` | Host package management. |
| `haproxy`, `ui_haproxy` | The edge proxy is a hand-managed systemd unit. |
| `longhorn` | Storage is [OpenEBS](/infrastructure/openebs.md); one node has nothing to replicate to. |
| `harbor` | Images pull from an external registry. |
| `ingress_nginx` | Only [Harbor](/infrastructure/harbor.md) uses it. |
| `kubernetes_node_feature_discovery` | Installs a device plugin that crashloops without the container toolkit. |

and adds three roles that stand in for infrastructure living outside the
cluster in other environments — a database server and a message broker on hosts
of their own, and node configuration applied at build time:

- **`local_node_prep`** — applies the `analysis`/`vice`/`batch`/`gpu` labels
  that scheduling and the image cache key off of, and strips the taints that
  carry them. On one node those taints would leave every DE service `Pending`:
  no service manifest carries a toleration.
- **`cnpg`** or **`local_db_endpoint`** — PostgreSQL, from whichever of the two
  places `local_db_provider` selects. See The database below.
- **`rabbitmq_k8s`** — a single-replica [RabbitMQ](/infrastructure/rabbitmq.md)
  in the cluster, because the `rabbitmq` role installs a broker on a host over
  SSH.

## Prerequisites

- A machine with the `k0s` binary on `PATH`. The cluster itself is installed by
  the bootstrap script below, and the database runs inside it unless
  `local_db_provider` is set to `host`.
- Outbound DNS, since the hostnames resolve through `sslip.io`.
- `ansible`, `kubectl` >= 1.31 (or `kustomize` >= 5.2), `helm` >= 3.16,
  `skaffold`, `golang-migrate` >= 4.18, `psql` >= 14, `gpg` >= 2.1,
  `openssl` >= 1.1.1, `slappasswd`, and `uv` (for `import_apps.yml`).
- A pull robot account on the image registry.
- The private `local-deployment` inventory repo.

## Host preparation

Done once, outside Ansible, and all of it needs `sudo`. The default StorageClass
is not among it: the `openebs` role sets that when `openebs_default_storage_class`
is true, which the local inventory does.

**1. Bring up the cluster:**

```bash
sudo ansible/scripts/bootstrap-local-k0s.sh
```

That installs a single-node k0s controller, waits for its API server, creates
the iRODS CSI driver's kubelet directories (otherwise made by a play needing
root on each worker), and writes `~/.kube/local-admin.conf` owned by the
invoking user. Pass `--reset` to tear an existing cluster down first.

Two details it handles that are easy to get wrong by hand. It uses `--single`,
giving a combined controller/worker with no taint — `--enable-worker` would add
`node-role.kubernetes.io/master:NoSchedule` instead, and nothing would schedule
until the `node-prep` tag stripped it. And it rewrites the kubeconfig's
`server:` to `127.0.0.1`, because k0s records whatever address the node had at
install time and keeps it, so a DHCP lease or a VPN interface appearing later
breaks every `kubectl` call.

The script prints the pod and service CIDRs at the end. The inventory's
`k8s_pods_cidr` and `k8s_services_cidr` must match them: those values become
local-exim's relay allowlist, and a mismatch silently rejects outbound mail
from every DE pod.

**2. Nothing, under the default `local_db_provider: cnpg`** — the database runs
in the cluster and needs no host preparation at all. Only the `host` provider
does; see below.

No `/etc/hosts` entry is needed either, for the database or for the DE
hostnames. See Hostnames and DNS below.

## The database

`local_db_provider` decides where PostgreSQL runs. It defaults to `cnpg`.

**`cnpg`** runs it in the cluster under
[CloudNativePG](https://cloudnative-pg.io/): the `cnpg` role installs the
operator, creates a single-instance `Cluster`, and publishes it. There is no
host preparation, and the database's lifetime matches the cluster's — tearing
the cluster down takes the databases with it, so a rebuild never inherits stale
ones.

**`host`** uses a PostgreSQL already running on the workstation, published by
`local_db_endpoint` as a selector-less Service plus EndpointSlice. The Service
points at the CNI bridge address (the first host address of the node's
podCIDR), which is node-local — unlike the node's registered `InternalIP`,
which may belong to an overlay interface and would expose the database well
beyond the machine. It needs, in `postgresql.conf`:

```
listen_addresses = '127.0.0.1,10.244.0.1'
```

and in `pg_hba.conf`, matching the cluster's pod CIDR:

```
host  all  all  10.244.0.0/16  scram-sha-256
```

**That is not enough on its own, and the way it fails is silent.** The bridge
address does not exist until the CNI creates it, which happens long after
PostgreSQL starts at boot — and PostgreSQL only *warns* when a
`listen_addresses` entry cannot be bound. It comes up looking healthy, listening
on loopback alone, and every DE service fails to reach the database with an
error pointing nowhere near the cause. Allow the address to be bound before it
exists, then restart PostgreSQL and check `ss -ltn | grep 5432` shows both:

```bash
echo 'net.ipv4.ip_nonlocal_bind = 1' | sudo tee /etc/sysctl.d/90-de-local-db.conf
sudo sysctl -p /etc/sysctl.d/90-de-local-db.conf
```

Avoiding that trap is the main reason to prefer `cnpg`.

### How both are reached

Either way, pods resolve the database through cluster DNS at
`groups['dbms'][0]`, and the control machine — which cannot resolve cluster DNS
— reaches the same server at `db_login_host`. ClusterIPs are routable from the
host as well as from pods, so under `cnpg` that address is simply the Service's
ClusterIP, pinned via `cnpg_service_cluster_ip` so it survives a rebuild and
the inventory needs no editing afterwards. `postgresql_init` is identical in
both cases, and identical to what QA and prod run.

`db_login_host` has to be set for `cnpg`: its default is `groups['dbms'][0]`,
which is a cluster DNS name the control machine cannot resolve. Set it to the
same address as `cnpg_service_cluster_ip`.

The `cnpg` role publishes its own Service rather than using the operator's
`<cluster>-rw`, for two reasons: the name can match `groups['dbms'][0]`, and
the address can be pinned, which the operator's own Services do not allow. It
selects the primary by label, so a failover would follow.

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
ansible/scripts/generate-local-ca.sh
```

It writes `rootCA.pem` and `rootCA-key.pem` to `~/.local/share/de-local-ca`
(override with `-d`), with the `pathlen:1` constraint set, and prints the
inventory settings to point at them. Re-running needs `-f`, since replacing the
root invalidates every certificate already issued beneath it.

Then trust it (sudo), which covers the system store — `curl`, and anything
else using the platform defaults:

```bash
sudo trust anchor --store ~/.local/share/de-local-ca/rootCA.pem
```

**Browsers usually need a second step.** Firefox and Chrome derivatives keep
their own NSS trust store rather than reading the system one. A
distro-packaged build on Fedora is linked against p11-kit and does pick up
system anchors, so it needs nothing further — but a Flatpak or Snap build is
sandboxed away from `/etc` entirely and cannot see them however they are
installed. Import the root into that browser's profile instead:

```bash
certutil -A -d sql:"<profile directory>" \
  -n "CyVerse DE local development CA" -t "CT,," \
  -i ~/.local/share/de-local-ca/rootCA.pem
```

`-t "CT,,"` trusts it for TLS server and client certificates and nothing else.
Close the browser first, since NSS holds the database open, and re-open it
afterwards. The profile directory is the one containing `cert9.db`: under
`~/.mozilla/firefox/<profile>` for a native install, or
`~/.var/app/<app-id>/.mozilla/firefox/<profile>` — or the browser's own
equivalent, such as `~/.var/app/app.zen_browser.zen/.zen/<profile>` — for a
Flatpak. `certutil` comes from `nss-tools`.

A browser warning while `curl` is happy is this and not a deployment problem.

Once the endpoints are up, verify with no `-k` and read the TLS result rather
than the HTTP status, which will be a redirect or a 500 until the backends
exist:

```bash
curl -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  https://de.10-96-0-100.sslip.io/
```

`verify=0` is the chain validating. A `path length constraint exceeded` means
the root has the wrong constraint; `unable to get local issuer certificate`
means it is not trusted yet.

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

Then the whole thing, in one command:

```bash
ansible-playbook -i "$INVENTORY" local.yml
```

That is the intended way to bring up a fresh cluster, and the plays are ordered
so it works unattended: the database server exists before the databases are
created, and the databases before Keycloak and Grouper need them.

The tags below exist for re-running a part of it. Each is also the order to
follow if you would rather go step by step, which is worth doing the first time
on a new machine — a failure is much easier to place:

| Tags | Brings up |
| --- | --- |
| `node-prep` | Node labels; removes the taints that repel DE services |
| `openebs` | The storage provider and the default StorageClass |
| `cert-manager` | cert-manager and its CRDs |
| `cert-issuers` | The local CA Secret and `default-cluster-issuer` |
| `traefik` | Gateway API CRDs, Traefik, its default certificate |
| `argo` | Argo Workflows and argo-events |
| `de-reqs` | Namespaces, the timezone ConfigMap, local-exim, the image-pull secret, the database server and its Service, RabbitMQ |
| `setup-databases` | The DE, notifications, metadata, grouper, qms, and portal databases, and their migrations |
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

Then `argo_resources.yml` and `bootstrap_portal_admin.yml`, which between them
create the Argo secrets and an account to log in with — there is none until the
second one runs, since LDAP holds only the two service accounts the seed
creates.

`argo_resources_secrets` selects which per-tool secrets to create. All but
`wc-data` read from files the inventory ships under `secrets/`, so an inventory
that does not run MATLAB or the NCBI submission tools lists only `wc-data`.

`bootstrap_portal_admin.yml` creates the account in four places in turn — LDAP,
the portal database, iRODS via portal-conductor, and the DE via terrain — so a
failure part-way leaves the earlier ones done. It is safe to re-run.

Then `import_apps.yml`, which puts something runnable in the DE. The
migrations seed three apps, but none of them have rows in the permissions
service, so the app listing is empty until this runs. It imports `DE Word
Count` and `CloudShell` as public apps — one batch app and one VICE app,
enough to exercise both execution paths — and `portal-delete-user` privately.
It has to follow the bootstrap playbook, since it authenticates as
`portal_bootstrap_user` and creating an app needs an account that already has a
DE workspace. See
[Copying Apps Between DE Instances](/playbooks/app-export-import.md) for the
bundle format and how to add to the set.

`image-cache` is the one thing an untagged run skips: it pre-pulls every image
in `vice_image_cache` onto the node's disk, which is a lot of disk and a lot of
pulling to do as a side effect. Ask for it by tag.

Two checks are worth making early, because both failures are far cheaper to
find here than after forty services are running. After `cert-issuers`, confirm
`default-cluster-issuer` reports `READY=True`. After `de-reqs`, confirm a pod
can actually reach the database — the host-side binding described above fails
silently, and every service depends on it:

```bash
kubectl -n de run pgtest --rm -it --restart=Never --image=postgres:16-alpine \
  --env=PGPASSWORD=<dbms_connection_pass> -- \
  psql -h db.de.svc.cluster.local -U de -d de -Atc 'select inet_server_addr()'
```

It should print the address of the database, whichever provider is in use.
Under `host`, `Connection refused` means PostgreSQL is listening on loopback
only.

## Tearing down

There are two teardowns, and which one to use depends on whether the point is
to get back to a clean DE or to prove a bring-up works from nothing.

**Keep the cluster** — `local-teardown.yml` removes the DE and, with no tags,
everything else `local.yml` installs. It requires an explicit confirmation,
which names the cluster it is about to empty:

```bash
ansible-playbook -i "$INVENTORY" local-teardown.yml -e local_teardown_confirm=yes
ansible-playbook -i "$INVENTORY" local-teardown.yml --tags de -e local_teardown_confirm=yes
```

The `de` tag leaves the gateway, cert-manager, Argo, storage and the
CloudNativePG operator in place, which is the fast loop when iterating on the
DE itself. Under `local_db_provider: cnpg` the database goes with the `de`
namespace either way. Under `host` it survives, and
`local_teardown_drop_databases: true` opts into dropping the databases and
roles — off by default, because that destroys data outside the cluster.

**Destroy the cluster** — `scripts/bootstrap-local-k0s.sh --reset`, then
reboot, then re-run the script without `--reset`.

The reason to prefer the playbook when either would do is the image cache: a
full DE is around 11 GiB across 50 images, and `k0s reset` discards all of it.
The reason to prefer the reset is that only it proves the runbook works on a
machine that has never run the DE.

Deleting namespaces before the storage provider matters, and is why the
playbook orders them that way: it lets the hostpath provisioner reclaim each
volume as its claim is released. `k0s reset` cannot — it removes the
PersistentVolume objects wholesale, leaving their directories behind under
`/var/openebs/local`, so the reset script deletes that tree itself.

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

**The portal's `account_*` reference tables no longer need seeding by hand.**
`bootstrap_portal_admin.yml` and self-registration both insert an `account_user`
row using subselects for a `Not Provided` row in `account_awarechannel`,
`account_ethnicity`, `account_fundingagency`, `account_gender`,
`account_occupation`, and `account_researcharea`; without those rows the
subselects return NULL and the insert dies on a NOT NULL constraint. `portal2`
migration `00003_reference_data` populates all of them, along with
`account_country` and `account_region`, so a `setup-databases` run against an
empty database leaves them complete. This was a manual step before that
migration existed — verify rather than assume if `portal_version` is pinned to
something older.

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

**Pods need the private CA for any server-side TLS to a DE hostname.** A
container trusts only what its image ships, so an endpoint served by the local
root is rejected however thoroughly the host and browser trust it. Setting
`de_ca_bundle_configmap` publishes the certificate and mounts it into the
services that call a DE endpoint — every service holding the Keycloak URL, some
twenty of them. Without it terrain rejects every authenticated request, and the
error names no certificate: a `SunCertPathBuilderException` surfacing as a 500.

VICE analyses need it too, and they are not covered by the service manifests:
their vice-proxy sidecar exchanges an authorization code with Keycloak
server-side, and its pod spec is built by the operator rather than templated
here. `vice_operator_ca_bundle_configmap` covers both the operator and the
sidecars — see [vice-operator](/services/vice-operator.md).

**Every runtime finds the certificate a different way, and ignores the other
runtimes' variable.** The manifests set all three, since each is inert where it
is not understood:

| Variable | Read by |
| --- | --- |
| `SSL_CERT_FILE` | OpenSSL, and so Go |
| `NODE_EXTRA_CA_CERTS` | Node |
| `REQUESTS_CA_BUNDLE` | python-requests |

Setting only `SSL_CERT_FILE` looks right and leaves every Node service with the
certificate mounted and unused. sonora is the one that shows it: the
authorization-code exchange is a server-side call to Keycloak, so login ends at
a bare `403 Access denied` from sonora rather than anything mentioning a
certificate, and Keycloak's own logs show a successful authentication.

A JVM reads none of them — it cannot be pointed at a PEM at all — so JVM
services get an init container that copies their own image's `cacerts` and
imports the CA into the copy, with `-Djavax.net.ssl.trustStore` added to the
shared `java-tool-options` ConfigMap. A service added later that makes such a
call needs the same volume, mount and variables added to its manifest; the gate
is already in the templates to copy.

To check a running pod directly rather than inferring from a failure:

```bash
kubectl -n de exec deploy/<service> -- node -e \
  "require('https').get('https://<keycloak host>/auth/realms/<realm>', \
   r => console.log(r.statusCode)).on('error', e => console.log(e.code))"
```

**Analyses write into a shared zone.** `irods_user` is a rodsadmin proxy
account, so this deployment has write access to every user's home collection in
the reused zone, and both deployments push ACLs and AVUs onto the same
collections. `de_default_output_folder` is set to a distinct name to keep
outputs out of the folders the other environments use, but that is containment,
not isolation. Bootstrapping an admin also creates a real account and home
collection in that zone, which outlives any number of local cluster rebuilds.

The accounts portal-conductor grants ownership of each new home collection to
must exist in the zone. `portal_conductor_irods_admin_user` defaults to `rods`,
the stock iRODS administrator, which in the CyVerse data store exists only in
the `cyverse.dev` zone — granting there fails with `CAT_INVALID_USER` *after*
the user and its password have been created, so it reads as a transient fault
rather than a misconfiguration. Confirm what the zone actually has before
assuming:

```sql
SELECT user_name, user_type_name, zone_name FROM r_user_main;
```

## Manual steps, and which are worth automating

Everything below is done by hand today. The table records why, so the list can
be worked down rather than rediscovered. "Blocker" means the deployment cannot
proceed without it.

| # | Step | Needs | Blocker | Automation notes |
| --- | --- | --- | --- | --- |
| 1 | `scripts/bootstrap-local-k0s.sh` | sudo | yes | Absorbs what were three separate steps: the k0s install, the kubeconfig, and the kubelet plugin directories. What remains manual is inherent — installing the cluster is the step that defines the machine, and it needs root. |
| 2 | Trust the local root CA — `trust anchor`, plus `certutil` per browser profile | sudo for the first | yes | Generation is now `scripts/generate-local-ca.sh`. The system-store half is one command; the browser half cannot be automated centrally, because each profile has its own NSS database and a sandboxed browser cannot read the host's trust configuration at all. |
| — | ~~PostgreSQL `listen_addresses`, `pg_hba.conf`, and `ip_nonlocal_bind`~~ | — | — | **Eliminated** under `local_db_provider: cnpg`, which runs the database in the cluster. Still required under `host`, and still the step whose omission fails silently after a reboot. |
| — | ~~Edge proxy TCP passthrough~~ | — | — | **Eliminated.** The pinned Traefik ClusterIP answers on 443 from the host, so no proxy sits in front of the cluster and no NodePort appears in a URL. |
| — | ~~Cluster DNS for the DE hostnames~~ | — | — | **Never needed.** sslip.io resolves from both the host and the cluster, so there is no CoreDNS edit to maintain — which also avoids fighting a resource k0s owns. |
| — | ~~`/etc/hosts` entry for the database name~~ | — | — | **Eliminated** by `db_login_host`, which lets the control machine reach PostgreSQL on loopback while pods use the cluster DNS name. One name no longer has to mean the same thing in two places. |
| — | ~~Generate the local root CA~~ | — | — | **Automated** by `scripts/generate-local-ca.sh`, with the `pathlen:1` constraint the endpoint chain requires. |
| — | ~~Check for leftover DE databases and roles~~ | — | — | **Automated.** `postgresql_init` fails up front naming any database whose locale provider it cannot reconcile, and declares every role it creates with `role_attr_flags: LOGIN`. |
| — | ~~Keycloak realm, clients, LDAP federation, group mapper~~ | — | — | **Automated** by the `keycloak_config` role (tag `keycloak-config`). Realm, 5 realm roles, required actions, LDAP federation with the standard plus DE-specific mappers, the `profile` scope claim mappers, all 8 clients, and the `vice-api` service-account role. |
| — | ~~Seed the portal `account_*` reference tables~~ | — | — | **Never needed now.** `portal2` migration `00003_reference_data` seeds every table the registration path reads. |

# Citations

* `ansible/local.yml`
* `ansible/roles/local_node_prep/`
* `ansible/roles/local_db_endpoint/`
* `ansible/roles/cnpg/`
* `ansible/local-teardown.yml`
* `ansible/scripts/bootstrap-local-k0s.sh`
* `ansible/roles/rabbitmq_k8s/`
* `ansible/roles/cluster_issuers/tasks/main.yml`
* `ansible/roles/postgresql_init/tasks/preflight.yml`
* `ansible/import_apps.yml`
* `ansible/roles/de_apps/`
* `ansible/scripts/bootstrap-local-k0s.sh`
* `ansible/scripts/generate-local-ca.sh`
* `ansible/scripts/generate-secrets.sh`
* [mkcert](https://github.com/FiloSottile/mkcert)
