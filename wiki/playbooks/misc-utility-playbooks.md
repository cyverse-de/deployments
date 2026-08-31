---
type: Runbook
title: Miscellaneous Utility Playbooks
description: A catalog of the small standalone playbooks - security mitigations, k3s-era cleanup, host surveys, database copies, config pushes, app imports, and GoCD kubeconfig transfer.
resource: /ansible
tags: [utilities, playbooks, maintenance, mitigations]
timestamp: 2026-08-28T00:00:00Z
---

Small standalone playbooks that don't fit a larger workflow. Node updates and
rolling reboots have their own page:
[Node OS Updates and Rolling Reboots](/playbooks/node-maintenance.md).

## dirty_frag_mitigation.yml

Mitigates the "Dirty Frag" kernel vulnerability (referenced in the play as
CVE-2024-2101) on `k8s_workers` by blacklisting the vulnerable `esp4`,
`esp6`, and `rxrpc` modules via `/etc/modprobe.d/dirty-frag.conf` and
attempting to unload them immediately. Run once fleet-wide when the
mitigation is needed; it is idempotent.

## disable_af_alg.yml / uninstall_disable_af_alg.yml

Installs (or, via the uninstall playbook, removes) a SystemTap-based
mitigation on all `k8s` hosts, five at a time. The role installs systemtap
plus matching kernel-devel/headers, compiles `disable_af_alg.stp` into a
kernel module, and runs it as the `disable-af-alg` systemd service, which
SIGKILLs any process opening an AF_ALG socket. The install verifies the
service is active, probes that an AF_ALG open actually gets killed, and
confirms the block was journaled. Run after adding nodes or a kernel change
(the module builds against the running kernel).

## k3s_uninstall.yml

Removes the old k3s distribution by running `k3s-agent-uninstall.sh` on
`k8s_workers` and `k3s-uninstall.sh` on `k8s_controllers`. Only for
retiring a k3s-era cluster; the current clusters run
[k0s](/infrastructure/kubernetes-cluster.md).

## print_host_distros.yml

Read-only survey: prints each `k8s` host's distribution and version
(AlmaLinux, Rocky, Ubuntu, CentOS) and a per-distro host summary. Run before
OS-dependent maintenance to see what you are dealing with.

## big_dumper.yml

Runs the `db_copy_prod` role on the control machine to copy production
databases into the target environment's DBMS. It `pg_dump`s the DE database
from `prod_db_host` (excluding bulky operational table data such as jobs,
job_steps, logins, sessions, and usage tables), drops and recreates the
receiving schema, and restores; separate task files (tags `de`, `metadata`,
`notifications`, `fix-grouper`) cover the other databases. Needs `pg_dump`/
`psql` locally plus production and target DB credentials. Use for refreshing
QA-like environments with production-shaped data.

## config_files.yml

Runs the `service_configurations` role on its own, regenerating the shared
`configs` secret without a full `kubernetes.yml` run — the standalone
equivalent of `--tags configure-services`. Run after changing inventory
values that feed service configuration.

## local-exim.yml

Deploys the `local-exim` mail relay on its own — the standalone equivalent of
the local-exim slice of `--tags de-reqs`, which otherwise also re-runs the
namespace, cert-issuer, timezone, and Harbor pull-secret tasks. It imports the
same task file the `k8s_de_reqs` role uses, so the two paths cannot drift.
[notifications](/services/notifications.md) relays outbound DE mail through this
deployment by default, though its `notifications_smtp_*` settings can point it
at an external relay directly and leave exim out of the path. The play first
asserts that `exim_smarthost` is set and does not point at loopback: the role
default does, which makes exim smarthost to itself and silently drops every
message. Note that the value is an exim host list, so a port needs a second
colon (`host::port`).

## openldap_community_group.yml

Backfills the `community` LDAP group on an already-deployed
[openldap-docker](/services/openldap-docker.md) instance. portal-conductor
adds every new portal user to that group during registration, but the seed
LDIF only loads on a fresh volume, so instances seeded before the group was
added to the template fail registration with LDAP "No Such Object". Runs from
localhost over a `kubectl port-forward` to the `openldap` service and asserts
`ldap_in_cluster`/`ldap_root_pw`; requires python-ldap on the control host.
Idempotent — safe to re-run.

## discoenv_analyses_cleanup.yml

Deletes a running discoenv-analyses deployment after the service's retirement
from this repo: removes the `discoenv-analyses` Deployment and the
`discoenv-analyses-configs` secret from the DE namespace (the service created
no Kubernetes Service object). Idempotent — deleting already-absent resources
succeeds silently.

## discoenv_users_cleanup.yml

Deletes a running discoenv-users deployment after the service's retirement
from this repo: removes the `discoenv-users` Deployment and the
`discoenv-users-configs` secret from the DE namespace (the service created no
Kubernetes Service object). Idempotent — deleting already-absent resources
succeeds silently.

## jex_adapter_cleanup.yml

Deletes a running jex-adapter deployment after the service's retirement from
this repo: its HTTP job-submission role was folded into app-exposer's `/batch`
endpoint, and apps and terrain now point their JEX base URL there. Removes the
`jex-adapter` Deployment, its `jex-adapter` Service, and the
`jex-adapter-configs` secret from the DE namespace. Idempotent — deleting
already-absent resources succeeds silently.

## qms_cleanup.yml

Deletes a running `qms` deployment after the service's merge into
[subscriptions](/services/subscriptions.md), which now serves the QMS `/v1`
API. Removes the `qms` Deployment, its `qms` Service, and the `qms-configs`
secret from the DE namespace. Idempotent.

Order matters: terrain resolves the QMS API through `terrain.qms.base-uri`,
whose compiled-in default is `http://qms`, so deploy subscriptions and
redeploy terrain with the config that repoints it *before* running this.

## qms_adapter_cleanup.yml

Deletes a running qms-adapter deployment after the service's retirement from
this repo: nothing publishes to the `qms.usages` AMQP routing key it consumed
(usage updates moved to NATS and the [subscriptions](/services/subscriptions.md)
service in 2022). Removes the `qms-adapter` Deployment, its `qms-adapter`
Service, and the `qms-adapter-configs` secret from the DE namespace.
Idempotent — deleting already-absent resources succeeds silently.

## nats_cleanup.yml

Removes the DE's NATS installation after its retirement from this repo. NATS
carried the QMS request/reply traffic between
[terrain](/services/terrain.md), the former data-usage-api,
[resource-usage-api](/services/resource-usage-api.md), and
[subscriptions](/services/subscriptions.md); all four now use the subscriptions
HTTP API. Uninstalls the `nats` Helm release and deletes the `nats-server-tls`,
`nats-client-tls`, and `selfsigned-ca` Certificates, the `ca-issuer` Issuer, and
the NATS secrets from the DE namespace. It first asserts that no workload still
mounts a NATS secret and fails with the offending pod names if one does, so a
half-migrated cluster can't be left with a service that cannot reconnect.
Idempotent — deleting already-absent resources succeeds silently. Leaves the
argo-events EventBus alone; that is a separate NATS instance under argo-events'
control.

## vice-operator-eks.yml

Brings up VICE on an AWS EKS cluster: the `vice-operator-eks` role
bootstraps the cluster and supporting services, then the playbook installs
the iRODS CSI driver and deploys the
[vice-operator](/services/vice-operator.md) service. Runs entirely from
localhost against the kubeconfig in scope; tags `vice-operator-eks`,
`irods-csi-driver`, and `vice-operator` select the phases.

## gocd_kubeconfig.yaml

Renders the cluster kubeconfig on the control machine
(`gocd_agent_kubeconfig` role) and transfers it to the `gocd_agent` hosts
(`gocd_kubeconfig_xfer` role) so [GoCD](/infrastructure/gocd.md) agents can
deploy into the cluster. Re-run whenever the cluster credentials rotate.

## import_apps.yml

Runs the `de_apps` role, which imports a set of app bundles into a deployment
with [appei](/playbooks/app-export-import.md). Useful for giving a new
deployment something runnable — a fresh DE's app listing is empty. Must follow
[bootstrap_portal_admin.yml](/playbooks/bootstrap-portal-admin.md), since it
authenticates as `portal_bootstrap_user`. Idempotent.

# Citations

[1] `ansible/dirty_frag_mitigation.yml` — module blacklist mitigation.
[2] `ansible/disable_af_alg.yml`, `ansible/uninstall_disable_af_alg.yml`, `ansible/roles/disable_af_alg/tasks/install.yml` — AF_ALG SystemTap mitigation and its verification steps.
[3] `ansible/k3s_uninstall.yml` — k3s removal.
[4] `ansible/print_host_distros.yml` — distro survey.
[5] `ansible/big_dumper.yml`, `ansible/roles/db_copy_prod/tasks/` — production database copy.
[6] `ansible/config_files.yml` — standalone service_configurations run.
[7] `ansible/local-exim.yml`, `ansible/roles/k8s_de_reqs/tasks/local_exim.yml` — standalone local-exim run and the shared task file it imports.
[8] `ansible/openldap_community_group.yml` — community group backfill for existing OpenLDAP deployments.
[9] `ansible/nats_cleanup.yml` — NATS Helm release, certificate, and secret teardown.
[10] `ansible/vice-operator-eks.yml` — VICE-on-EKS bootstrap.
[11] `ansible/gocd_kubeconfig.yaml` — kubeconfig transfer to GoCD agents.
[12] `ansible/import_apps.yml`, `ansible/roles/de_apps/` — default app set import.
[13] `ansible/qms_cleanup.yml` — QMS Deployment, Service, and config secret teardown.
