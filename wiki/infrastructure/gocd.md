---
type: Service
title: GoCD
description: The GoCD continuous-deployment server and agents installed on hosts outside the cluster by gocd.yml, including agent tooling and kubeconfig distribution.
resource: /ansible/gocd.yml
tags: [gocd, ci-cd, kubeconfig, playbooks]
timestamp: 2026-07-20T00:00:00Z
---

GoCD provides continuous deployment for the DE. It is deployed on hosts outside the
Kubernetes cluster to simplify the automation of cluster maintenance. GoCD is off by
default (`gocd_enabled: false`); when enabled, `gocd_external_domain` must be set — it is
both the URL agents use to reach the server and the hostname
[HAProxy](/infrastructure/haproxy.md) (`ui_haproxy`) fronts GoCD with.

## Playbooks

```bash
ansible-playbook -i <inventory> -K gocd.yml            # server + agents + kubeconfig
ansible-playbook -i <inventory> -K gocd_kubeconfig.yaml # kubeconfig transfer only
```

`gocd.yml` installs `go-server` on the `gocd_server` group and `go-agent` on the
`gocd_agent` group (both from the upstream GoCD apt/yum repositories, with Debian and
Red Hat task paths), then imports `gocd_kubeconfig.yaml`. Both plays first gather facts
about the `de_haproxy` hosts; on Debian the server opens port 8153 via ufw only to those
proxy IPs.

## Agent setup

The `gocd_agent` role points each agent at the server by writing
`wrapper.app.parameter.101=https://{{ gocd_external_domain }}/go` into the go-agent
wrapper config, and installs the tooling pipelines need: `kubectl` (from the pkgs.k8s.io
v1.30 repo), `skaffold` (downloaded from `gocd_skaffold_url`), Ansible, `git`,
python3-pip with the `psycopg2` and `kubernetes` modules, and the `golang-migrate`
`migrate` binary. On Red Hat servers the same tools are installed on the server host too
(the `gocd_server` role includes the agent's `redhat_tools.yml`).

## Kubeconfig distribution

`gocd_kubeconfig.yaml` runs two roles so agents can operate on the cluster:

- `gocd_agent_kubeconfig` (on the control machine, against `k8s_controllers[0]`): runs
  `k0sctl kubeconfig --config <inventory-parent>/k0sctl.yaml` and writes the result to
  `./{{ ns }}.kubeconfig`. It expects `k0sctl.yaml` to sit in the parent directory of the
  inventory, and it will not overwrite an existing file (`creates:`), so delete the local
  copy to force a refresh.
- `gocd_kubeconfig_xfer` (on the `gocd_agent` hosts): copies that file to
  `/var/go/k8s_{{ ns }}.yml`, owned by the `go` user.

# Citations

[1] `ansible/gocd.yml` — server/agent plays, de_haproxy fact gathering, kubeconfig import.
[2] `ansible/gocd_kubeconfig.yaml` — the kubeconfig generation-and-transfer playbook.
[3] `ansible/roles/gocd_server/tasks/` — repo setup, go-server install, ufw rule scoped to de_haproxy.
[4] `ansible/roles/gocd_agent/tasks/` — go-agent install, server URL wiring, agent tooling.
[5] `ansible/roles/gocd_agent_kubeconfig/tasks/main.yml` and `ansible/roles/gocd_kubeconfig_xfer/tasks/main.yml` — k0sctl kubeconfig export and copy to agents.
[6] `ansible/roles/common/defaults/main.yml` — `gocd_enabled`, `gocd_external_domain`, `gocd_skaffold_url` defaults.
[7] `ansible/README.md` — GoCD section (deployed outside the cluster; playbook table).
