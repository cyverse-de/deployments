---
type: Service
title: HTCondor
description: The HTCondor pool that runs DE batch analyses — inventory groups, the condor.yml install playbook, node configuration, and the uninstall playbook.
resource: /ansible/condor.yml
tags: [condor, htcondor, batch, docker, playbooks]
timestamp: 2026-07-20T00:00:00Z
---

HTCondor is the batch-execution system for DE analyses. The pool runs on hosts outside the
Kubernetes cluster, organized in the inventory as a `condor` parent group with three
children: `condor_manager` (central manager), `condor_submit` (submission node), and
`condor_worker` (execute nodes) — see `ansible/example/inventory/01_condor`.

## Playbooks

- `ansible/condor.yml` — installs and configures the whole pool. Plays are tagged
  `manager`, `submission`, and `worker` so a subset of node types can be targeted.
- `ansible/condor_requirements.yml` — an Ansible Galaxy requirements file pulling
  `cyverse-ansible.docker`; install it before the first run
  (`ansible-galaxy install -r condor_requirements.yml`).
- `ansible/uninstall_condor.yml` — stops and disables the `condor` service, removes the
  package, and deletes `/etc/condor`, `/var/lib/condor`, and the downloaded install script.

## What condor.yml does

1. Installs prerequisites (python3-pip, curl, the Python `docker` module), sets the
   timezone, and installs Docker via the `CyVerse-Ansible.docker` role on all pool hosts.
2. Downloads the upstream installer from https://get.htcondor.org and runs it with
   `--password {{ condor_pool_password }}`; each host gets `--central_manager`,
   `--execute`, and/or `--submit` flags (all pointed at the first `condor_manager` host)
   based on its group membership. Both variables come from inventory group_vars.
3. The `condor_configuration` role drops three files into `/etc/condor/config.d/`: a
   single partitionable slot spanning 100% of CPUs, `UID_DOMAIN = {{ condor_uid_domain }}`
   with `TRUST_UID_DOMAIN`, and startd attributes advertising `HasDocker` and
   `HAS_CYVERSE_ROAD_RUNNER` (which DE job requirements expressions match against).
4. The submit node additionally gets the `job-user` and `de-road-runner` roles; workers get
   `job-user`, `de-docker-logging-plugin`, `de-image-janitor`, `de-network-pruner`, and
   `condor-worker-docker-registries`.
5. `/opt/image-janitor` on workers is chowned to the `condor` user, and the `condor`
   service is restarted and enabled everywhere.

The `condor-worker-docker-registries` role runs `docker login` as the `condor` user for
each entry in the optional `docker_registries` list (items with `host`, `user`, and
`password`), writing `~condor/.docker/config.json` so workers can pull tool images from
private registries such as [Harbor](/infrastructure/harbor.md).

For debugging jobs on the pool, see
[Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md).

# Citations

[1] `ansible/condor.yml` — the install playbook: prerequisites, installer invocation, per-group roles, tags.
[2] `ansible/condor_requirements.yml` — Galaxy requirements for the Docker role.
[3] `ansible/uninstall_condor.yml` — the removal playbook.
[4] `ansible/roles/condor_configuration/` — the templated `/etc/condor/config.d/` files.
[5] `ansible/roles/condor-worker-docker-registries/tasks/main.yml` — registry logins for the condor user.
[6] `ansible/example/inventory/01_condor` — the inventory group layout.
