---
type: Service
title: Kubernetes Cluster
description: How the k0s cluster is provisioned — node preparation, firewall, API load balancer, k0sctl apply, and the kubernetes.yml orchestration and tags.
resource: /ansible/kubernetes.yml
tags: [kubernetes, k0s, k0sctl, calico, firewall, nodes, provisioning, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

The DE runs on a k0s Kubernetes cluster provisioned by `k0sctl` and orchestrated end-to-end by
`ansible/kubernetes.yml`. Earlier deployments used k3s; a few k3s-era leftovers remain in the
repo (`ansible/roles/kubernetes_gpu_workers/`, `ansible/roles/kubernetes_k3s_uninstall/`,
`ansible/k3s_uninstall.yml`) but current provisioning is k0s throughout.

## Inventory groups

From `ansible/example/inventory/05_k8s`: `k8s` is the umbrella group containing `k8s_nodes` and
`k8s_api_proxy`. `k8s_nodes` splits into `k8s_controllers` and `k8s_workers`, and `k8s_workers`
further into `k8s_de_workers` (DE services), `k8s_vice_workers`, `k8s_gpu_workers` (see
[GPU Workers](/infrastructure/gpu-workers.md)), and `k8s_opensearch_workers`.

## Cluster creation: k8s_cluster and k0sctl

The `k8s_cluster` role (tags `create-cluster`, `add-nodes`) runs locally against
`k8s_controllers[0]`. It expects a `k0sctl.yaml` in the parent directory of the inventory
directory (`inventory_dir | dirname`), runs `k0sctl apply --config` against it, then writes the
resulting kubeconfig to the path in `kubeconfig` with mode 0600. The k0sctl file — see
`ansible/example/k0sctl.yaml` — defines hosts, roles (controller, worker, controller+worker),
Calico networking, worker profiles (e.g. an `irods-node` profile with system/kube reservations),
and per-node labels and taints such as `analysis=true,vice=true` with taint
`analysis=only:NoSchedule` for analysis-only workers.

## Node preparation

Roles that run on the hosts themselves, all carrying the `prep-nodes` / `add-nodes` tags:

- `nvidia_drivers` on `k8s_gpu_workers` (`install-gpu-drivers`) — see
  [GPU Workers](/infrastructure/gpu-workers.md).
- `haproxy` + `k8s_haproxy` on `k8s_api_proxy` (tag `haproxy`) — adds HAProxy TCP listen blocks
  balancing the Kubernetes API (`k8s_api_port`, default 6443), konnectivity (8132), and the
  controller join API (9443) across all `k8s_controllers`, and opens those ports in the local
  firewall. Nodes register through this load balancer; see [HAProxy](/infrastructure/haproxy.md).
- `timezone` on `k8s_de_workers` (tag `timezone`).
- `k8s_nodes` on all `k8s_nodes` — installs containerd (docker-ce repo on RedHat), runc, helm,
  and calicoctl; disables swap and SELinux enforcement; enables IP forwarding; loads the
  `iscsi_tcp`, `overlay`, and `br_netfilter` kernel modules; installs wireguard, NFS, and iSCSI
  client packages; verifies the kernel supports NFS 4.1/4.2 (the run fails if not); makes
  `/dev/dri` devices world-writable via udev; creates a `k0s` group with passwordless sudo; and
  tells NetworkManager to leave Calico interfaces unmanaged.
- `k8s_firewalld` on all `k8s_nodes` (tag `firewall`) — detects whether firewalld or ufw is
  active and opens the cluster ports (6443, 2380 etcd, 10250 kubelet, 9443 join, 179 BGP,
  8132 konnectivity, 4789/udp Calico VXLAN, and NodePorts 30000-32767), trusting the
  10.42.0.0/16 pod and 10.43.0.0/16 service subnets.

## In-cluster setup after creation

Subsequent plays in `kubernetes.yml` run locally against `k8s_controllers[0]` using the
generated kubeconfig: [cert-manager](/infrastructure/cert-manager.md) and cluster issuers, Argo,
the [ingress controllers](/infrastructure/ingress.md), [Longhorn](/infrastructure/longhorn.md)
and [OpenEBS](/infrastructure/openebs.md) storage, [Harbor](/infrastructure/harbor.md) (opt-in
tag), `k8s_de_reqs` (tag `de-reqs`: DE namespaces, the namespaced default issuer, timezone
ConfigMap, local exim, and the Harbor image-pull secret), OpenLDAP,
[Keycloak](/infrastructure/keycloak.md) (opt-in tag), service configuration and secrets
(`configure-services`, `secrets`), `kubernetes_ingress` (tag `ingress`), `kubernetes_networking`
(tags `networking`, `nodeports` — NodePort services for kifshare, terrain, and
job-status-listener that [HAProxy](/infrastructure/haproxy.md) fronts),
[NATS](/infrastructure/nats.md), [OpenSearch](/infrastructure/opensearch.md), node feature
discovery (`feature-discovery`), [Grouper](/infrastructure/grouper.md) init, the VICE image
cache, the iRODS CSI driver (tag `irods-csi-driver`, including plugin directories created on
workers under `/var/lib/k0s/kubelet/`), and finally service deploys (`deploy-all-services` or
`deploy-single-service` with `-e project=<name>`), cronjobs, and optional
[Jaeger](/infrastructure/jaeger.md).

Useful tag groupings: `prep-nodes` covers everything needed before cluster creation;
`add-nodes` covers node prep plus `create-cluster` for growing the cluster; `databases` covers
the PostgreSQL plays at the top of the playbook. See
[Full Deployment](/playbooks/full-deployment.md) for the end-to-end procedure.

# Citations

[1] `ansible/kubernetes.yml` — play ordering, host groups, and tags.
[2] `ansible/roles/k8s_cluster/tasks/main.yml` — k0sctl apply and kubeconfig generation.
[3] `ansible/example/k0sctl.yaml` — example cluster spec with Calico, labels, taints, and worker profiles.
[4] `ansible/example/inventory/05_k8s` — inventory group hierarchy.
[5] `ansible/roles/k8s_nodes/tasks/main.yml` — node preparation details.
[6] `ansible/roles/k8s_firewalld/tasks/main.yml` — firewalld/ufw port openings.
[7] `ansible/roles/k8s_haproxy/tasks/main.yml`, `ansible/roles/k8s_haproxy/templates/00_k8s.cfg.j2` — API load balancer configuration.
[8] `ansible/roles/kubernetes_networking/tasks/main.yml` — kifshare/terrain/job-status-listener NodePorts.
[9] `ansible/roles/k8s_de_reqs/tasks/main.yml` — DE prerequisite task files.
[10] `ansible/roles/common/defaults/main.yml` — `k8s_api_port`, `k8s_version`, `helm_version`, `calico_version` defaults.
