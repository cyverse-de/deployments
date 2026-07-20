---
type: Runbook
title: Node OS Updates and Rolling Reboots
description: OS package updates with update_nodes.yml and drained, rolling reboots of cluster nodes with reboot_nodes.yml.
resource: /ansible/update_nodes.yml
tags: [nodes, maintenance, updates, reboot, drain]
timestamp: 2026-07-20T00:00:00Z
---

Two playbooks handle routine OS maintenance on the
[Kubernetes cluster](/infrastructure/kubernetes-cluster.md) nodes.

## update_nodes.yml — OS package updates

Updates packages on all hosts in the `k8s` group, then runs a second pass
over `k8s_controllers` with `serial: 1` (one controller at a time). RedHat-family
hosts get `yum update -y --disablerepo=kubernetes` (the kubernetes repo is
excluded so package updates can't move the Kubernetes components);
Debian/Ubuntu hosts get an `apt` full upgrade. It only updates packages — it
does not reboot, so follow with `reboot_nodes.yml` when a kernel or other
reboot-requiring update lands.

```bash
ansible-playbook -i <inventory> -K update_nodes.yml
```

## reboot_nodes.yml — rolling reboots

Reboots `k8s_workers` and then `k8s_controllers`, five hosts at a time
(`serial: 5`). For each host it:

1. Drains the node via the Kubernetes API (`kubernetes.core.k8s_drain`,
   deleting emptyDir data, ignoring DaemonSets; drain errors are ignored so a
   stuck pod can't wedge the play).
2. Reboots the host.
3. Waits for the node to report `Ready`.
4. Uncordons the node.

The drain/uncordon steps run from the control machine against the cluster
API, so `kubeconfig` must be set for the target cluster (the play exports it
as `KUBECONFIG`).

```bash
ansible-playbook -i <inventory> -K reboot_nodes.yml
```

# Citations

[1] `ansible/update_nodes.yml` — the package-update playbook.
[2] `ansible/reboot_nodes.yml` — the drain/reboot/uncordon playbook.
