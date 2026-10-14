---
type: Playbook
title: VICE Image Caching
description: The three mechanisms for caching VICE images - the kube-fledged image_cache role, the legacy vice-cache Job playbook, and manual-mirror ECR mirroring for EKS.
resource: /ansible/vice_image_cache.yml
tags: [vice, images, cache, kube-fledged, harbor, ecr, eks]
timestamp: 2026-10-14T00:00:00Z
---

VICE app images are large, so these mechanisms exist to cut VICE launch
times. The first two pre-pull images onto the nodes that run analyses; the
third, for EKS, mirrors them into ECR instead.

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

## manual-mirror mode (EKS)

EKS Auto Mode nodes don't last, so pre-pulling onto them doesn't help, and ECR
can't use a self-hosted Harbor as a pull-through upstream. EKS inventories
therefore set `image_cache_mode: manual-mirror`, and caching works in two
parts:

1. `ansible/scripts/setup-ecr-repos.sh` creates per-cluster ECR repos (with a
   lifecycle policy) and grants the EKS node role pull access.
   `ansible/scripts/mirror-images-to-ecr.sh` then copies each image from
   Harbor into ECR with `skopeo copy --all`.
2. [vice-operator](/services/vice-operator.md) runs with
   `--image-cache-mode=manual-mirror` and reads a mapping file at startup.
   At launch it rewrites any analysis image ref that has a mapping to the ECR
   copy; unmapped images pass through unchanged.

One file, `ansible/roles/services/vice-operator/files/repos.json`, drives all
three: a flat JSON object of `{"<upstream ref>": "<fully qualified ECR
ref>"}`. The vice-operator role renders it into the `vice-operator-repos`
ConfigMap, mounted at `/etc/cyverse/de/repos.json`.

To cache a new image: add its entry to `repos.json`, run both scripts
(against a one-entry copy of the file to copy only that image), wait for the
copy to finish, then redeploy with
`ansible-playbook -i <inventory> vice-operator-eks.yml --tags vice-operator`
and run `kubectl rollout restart deploy/vice-operator`. The restart is
required because the Deployment doesn't change when only the ConfigMap does,
and the operator reads the file only at startup. Redeploy only after the copy
succeeds, or launches of the image fail with `ImagePullBackOff`. Then commit
`repos.json`. The `caching-vice-images-in-aws` skill (`skills/`) has the full
procedure and its pitfalls.

# Citations

[1] `ansible/vice_image_cache.yml` — the legacy playbook entry point.
[2] `ansible/roles/vice-cache/tasks/main.yml` — the per-image cache Jobs.
[3] `ansible/roles/image_cache/tasks/main.yml` — kube-fledged install, pull secret, and ImageCache resource.
[4] `ansible/roles/common/defaults/main.yml` — the `vice_image_cache` and `vice_cache_images` image lists.
[5] `ansible/scripts/setup-ecr-repos.sh` — ECR repo creation, lifecycle policy, and node-role pull policy.
[6] `ansible/scripts/mirror-images-to-ecr.sh` — the skopeo Harbor-to-ECR copy.
[7] `ansible/roles/services/vice-operator/files/repos.json` — the upstream-to-ECR image mapping.
[8] `ansible/roles/services/vice-operator/templates/vice_operator.yml.j2` — the repos ConfigMap and `--image-cache-mode`/`--repos-file` flags.
