---
type: Runbook
title: Miscellaneous Utility Playbooks
description: A catalog of the small standalone playbooks - security mitigations, k3s-era cleanup, host surveys, database copies, config pushes, and GoCD kubeconfig transfer.
resource: /ansible
tags: [utilities, playbooks, maintenance, mitigations]
timestamp: 2026-07-22T00:00:00Z
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

## openldap_community_group.yml

Backfills the `community` LDAP group on an already-deployed
[openldap-docker](/services/openldap-docker.md) instance. portal-conductor
adds every new portal user to that group during registration, but the seed
LDIF only loads on a fresh volume, so instances seeded before the group was
added to the template fail registration with LDAP "No Such Object". Runs from
localhost over a `kubectl port-forward` to the `openldap` service and asserts
`ldap_in_cluster`/`ldap_root_pw`; requires python-ldap on the control host.
Idempotent — safe to re-run.

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

# Citations

[1] `ansible/dirty_frag_mitigation.yml` — module blacklist mitigation.
[2] `ansible/disable_af_alg.yml`, `ansible/uninstall_disable_af_alg.yml`, `ansible/roles/disable_af_alg/tasks/install.yml` — AF_ALG SystemTap mitigation and its verification steps.
[3] `ansible/k3s_uninstall.yml` — k3s removal.
[4] `ansible/print_host_distros.yml` — distro survey.
[5] `ansible/big_dumper.yml`, `ansible/roles/db_copy_prod/tasks/` — production database copy.
[6] `ansible/config_files.yml` — standalone service_configurations run.
[7] `ansible/openldap_community_group.yml` — community group backfill for existing OpenLDAP deployments.
[8] `ansible/vice-operator-eks.yml` — VICE-on-EKS bootstrap.
[9] `ansible/gocd_kubeconfig.yaml` — kubeconfig transfer to GoCD agents.
