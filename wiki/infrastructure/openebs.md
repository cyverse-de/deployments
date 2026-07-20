---
type: Service
title: OpenEBS
description: How OpenEBS cluster storage is deployed by the opt-in openebs role in kubernetes.yml, and the kustomize/kubectl versions it requires.
resource: /notes/storage.md
tags: [openebs, storage, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

OpenEBS is deployed by the `openebs` Ansible role. It is opt-in (`openebs_enabled`
defaults to `false`), so enable it in your inventory's group_vars or pass it on the
command line:

```bash
ansible-playbook -i <inventory> --tags openebs -e openebs_enabled=true kubernetes.yml
```

The role renders the kustomization on the control machine, so it needs `kustomize` >= v5.2.0
or `kubectl` >= v1.31 on the PATH (older versions reject the overlay's multi-document patch
file). The role waits for the OpenEBS workloads to become ready before finishing.

OpenEBS replaced Longhorn as the cluster storage layer; see
[Longhorn Teardown](/playbooks/longhorn-teardown.md) for removing a previous
Longhorn install.

# Citations

[1] `notes/storage.md` — source document for this page.
[2] `ansible/roles/openebs/` — the role that deploys OpenEBS.
