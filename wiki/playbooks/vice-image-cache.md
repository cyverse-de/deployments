---
type: Playbook
title: VICE Image Caching
description: The two mechanisms for pre-pulling VICE images onto worker nodes - the kube-fledged image_cache role and the legacy vice-cache Job playbook.
resource: /ansible/vice_image_cache.yml
tags: [vice, images, cache, kube-fledged, harbor]
timestamp: 2026-07-20T00:00:00Z
---

VICE app images are large, so both mechanisms exist to pre-pull them onto the
nodes that run analyses, cutting VICE launch times.

## image_cache role (current, in kubernetes.yml)

The `image_cache` role runs in `kubernetes.yml` under the `image-cache` tag:

```bash
ansible-playbook -i <inventory> --tags image-cache kubernetes.yml
```

It installs [kube-fledged](https://github.com/senthilrch/kube-fledged) via
its Helm chart into an `image-cache` namespace (30m pull deadline, 1h cache
refresh), creates a [Harbor](/infrastructure/harbor.md) image-pull secret
(`vice_image_pull_secret`) from `harbor_robot_name`/`harbor_robot_secret`,
and applies an `ImageCache` resource named `vice-image-cache`. kube-fledged
then keeps every image in the `vice_image_cache` list (defaults in
`roles/common/defaults/main.yml`: vice-proxy, porklock, vice-file-transfers,
the common Jupyter/RStudio images, and others) pulled on all nodes labeled
`analysis: "true"`, refreshing hourly.

## vice_image_cache.yml (legacy k3s playbook)

`vice_image_cache.yml` runs the `vice-cache` role against
`k3s_controllers[0]` — it predates the k0s cluster layout and is only
relevant to a k3s-era inventory. For each image in `vice_cache_images` it
creates a one-shot Kubernetes Job in `vice_ns` (default `vice-apps`) whose
pod runs `true`; pulling the image onto the node is the entire point. The
Jobs tolerate the `vice=only:NoSchedule` taint and require nodes labeled
`vice: "true"`, so images land on the VICE workers. There is no refresh —
re-run the playbook to re-prime, and delete completed `cache-*` Jobs before
re-running since the Job spec is immutable once created.

Both roles apply resources with `kubeconfig` exported as `KUBECONFIG`, so set
it (or the inventory var) to the target cluster first.

# Citations

[1] `ansible/vice_image_cache.yml` — the legacy playbook entry point.
[2] `ansible/roles/vice-cache/tasks/main.yml` — the per-image cache Jobs.
[3] `ansible/roles/image_cache/tasks/main.yml` — kube-fledged install, pull secret, and ImageCache resource.
[4] `ansible/roles/common/defaults/main.yml` — the `vice_image_cache` and `vice_cache_images` image lists.
