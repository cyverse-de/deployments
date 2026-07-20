---
type: Playbook
title: Portal Exim Mail Relay
description: How portal-exim.yml deploys an exim4 SMTP relay into the portal namespace for outbound portal mail.
resource: /ansible/portal-exim.yml
tags: [portal, exim, smtp, mail]
timestamp: 2026-07-20T00:00:00Z
---

`portal-exim.yml` runs the `portal-exim` role, which creates a Kubernetes
Deployment named `exim` in the portal namespace (`portal_namespace`, default
`cyverse-portal`). It gives the user portal an in-cluster SMTP relay for
outbound mail (registration confirmations, notifications).

```bash
ansible-playbook -i <inventory> portal-exim.yml
```

The play nominally targets the `dbms` group but runs with
`connection: local` and delegates the Kubernetes work to localhost, applying
the manifest against the cluster selected by `kubeconfig`.

## What gets deployed

* Two replicas of `imixs/exim4:latest`, forced onto separate nodes by a
  required pod anti-affinity on the `app: exim` label.
* `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`, listening on
  port 25. The pods mount the host's `/etc/localtime` and the `timezone`
  ConfigMap so mail timestamps match the nodes.
* The manifest is applied with `force: true`, so re-runs replace the
  Deployment outright.

## Variables

The container is configured entirely through environment variables from the
inventory (defaults in `roles/common/defaults/main.yml` are placeholders):

* `exim_smarthost` — upstream relay in `host:port` form.
* `exim_password` — smarthost credential.
* `exim_allowed_senders` — colon-separated CIDRs allowed to relay; the role
  prepends `k8s_pods_cidr` and `k8s_services_cidr` so in-cluster pods and
  services can always send.
* `portal_namespace`, `kubeconfig`.

# Citations

[1] `ansible/portal-exim.yml` — the playbook entry point.
[2] `ansible/roles/portal-exim/tasks/main.yml` — the exim Deployment manifest and its variables.
[3] `ansible/roles/common/defaults/main.yml` — `exim_*` and `portal_namespace` defaults.
