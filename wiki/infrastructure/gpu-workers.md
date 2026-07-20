---
type: Service
title: GPU Workers
description: How GPU worker nodes get NVIDIA drivers, a container-toolkit runtime, and device-plugin labeling so VICE analyses can schedule onto them.
resource: /ansible/roles/nvidia_drivers
tags: [gpu, nvidia, cuda, node-feature-discovery, device-plugin, vice, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

GPU-equipped worker nodes live in the `k8s_gpu_workers` inventory group (a child of
`k8s_workers`; see [Kubernetes Cluster](/infrastructure/kubernetes-cluster.md)). Provisioning
has three layers: host drivers, container runtime integration, and in-cluster discovery.

## Host drivers: nvidia_drivers

The `nvidia_drivers` role runs on `k8s_gpu_workers` either via the standalone
`ansible/nvidia_drivers.yml` playbook or in `kubernetes.yml` under the `install-gpu-drivers`
(also `prep-nodes` / `add-nodes`) tags, before cluster creation. It fails fast if `lspci` finds
no NVIDIA device, applies a full system update, enables the CRB and EPEL repos plus NVIDIA's
`cuda-rhel9` repo (the role is RHEL9-family specific), installs kernel headers and build/DKMS
dependencies, blacklists the Nouveau driver and regenerates the initramfs, then installs the
`@nvidia-driver:latest-dkms` module stream and CUDA development libraries. Several steps notify
a reboot handler, so expect the node to reboot during the run.

## Runtime integration: nvidia_container_toolkit

After the cluster exists, the `nvidia_container_toolkit` role runs on `k8s_gpu_workers` in
`kubernetes.yml` (tags `nvidia-container-toolkit`, `post-k8s-tasks`, `prep-nodes`, `add-nodes`).
It installs the NVIDIA container toolkit packages and runs
`nvidia-ctk runtime configure --set-as-default`, writing a containerd drop-in at
`nvidia_container_toolkit_runtime_config_path` (default `/etc/k0s/containerd.d/nvidia.toml`,
matching k0s's containerd config-fragment directory) for the runtime named by
`nvidia_container_toolkit_runtime` (default `containerd`).

## Discovery and labeling: kubernetes_node_feature_discovery

The `kubernetes_node_feature_discovery` role (tag `feature-discovery`, run against the cluster
from `k8s_controllers[0]`) installs two Helm charts into `kube-system`: node-feature-discovery,
and the NVIDIA device plugin (chart version 0.17.1) with NFD disabled in-chart and GPU Feature
Discovery (`gfd`) enabled — so GPU nodes are labeled automatically from detected hardware rather
than by hand. Both charts tolerate the `nvidia.com/gpu`, `gpu=true`, and `analysis=only`
NoSchedule taints so their daemonsets can reach tainted analysis and GPU nodes. Node labels and
taints themselves are set in the k0sctl spec (see `ansible/example/k0sctl.yaml`).

The device plugin's `nvidia.com/gpu` resources and GFD labels are what let VICE and batch
analyses request GPUs; the vice-operator deployment consumes `vice_operator_gpu_*` variables
(vendor, models, model-affinity key) to steer GPU analyses. See
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md) for scheduling issues.

Note: `ansible/roles/kubernetes_gpu_workers/` is a leftover from the k3s era (it installs a k3s
agent with `--node-label=gpu=true --node-taint=vice=true:NoSchedule`) and is not referenced by
any current playbook.

# Citations

[1] `ansible/roles/nvidia_drivers/tasks/main.yml` — driver install, Nouveau blacklist, reboot handler.
[2] `ansible/nvidia_drivers.yml` — standalone playbook targeting `k8s_gpu_workers`.
[3] `ansible/kubernetes.yml` — `install-gpu-drivers`, `nvidia-container-toolkit`, and `feature-discovery` tags.
[4] `ansible/roles/nvidia_container_toolkit/tasks/main.yml` — nvidia-ctk runtime configuration.
[5] `ansible/roles/common/defaults/main.yml` — `nvidia_container_toolkit_runtime*` defaults.
[6] `ansible/roles/kubernetes_node_feature_discovery/tasks/main.yml` — NFD and device-plugin charts, tolerations, GFD.
[7] `ansible/roles/kubernetes_gpu_workers/tasks/main.yml` — legacy k3s-era role, unreferenced by playbooks.
[8] `ansible/roles/services/vice-operator/templates/vice_operator.yml.j2` — GPU model/vendor flags consumed by vice-operator.
