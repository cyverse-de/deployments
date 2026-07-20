---
type: Playbook
title: Argo Installation and Workflow Resources
description: How the argo role installs Argo Workflows/Events and how argo_resources.yml loads the secrets that batch workflows mount.
resource: /ansible/argo_resources.yml
tags: [argo, workflows, argo-events, batch, secrets]
timestamp: 2026-07-20T00:00:00Z
---

Batch analyses run as Argo Workflows (managed by app-exposer). Two roles are
involved: `argo` installs the machinery, and `argo_resources` loads the
data-container secrets some workflows mount.

## argo role (in kubernetes.yml, tags argo / de-reqs)

Installs Argo Workflows and Argo Events from templated manifests into
`argo_ns` (default `argo`) and `argo_events_ns` (default `argo-events`).
Beyond the base install it creates:

* The `argo-executor` ClusterRole/ServiceAccount/binding (create/patch/delete
  on `workflowtaskresults`).
* The `irods-config` ConfigMap in the argo namespace with the
  [iRODS](/infrastructure/irods.md) host, port, user, password, and zone.
* A `webhook` EventSource with `/batch`, `/batch/cleanup`, and `/vice`
  endpoints, plus sensors that log batch status, POST cleanup requests to
  `app-exposer`, and forward status updates to
  [job-status-listener](/services/job-status-listener.md). See
  [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md).

## argo_resources.yml (standalone playbook)

```bash
ansible-playbook -i <inventory> argo_resources.yml
```

Runs the `argo_resources` role (tags `argo-resources`, `argo`) on the control
machine against the cluster selected by `kubeconfig`. It creates opaque
Secrets in `argo_ns` used as data containers by specific workflows: a
`wc-data-latest` test secret, `matlab-mcr-2017b-data-v1-0` (an iRODS env
file), the NCBI SRA submit config/schema/template bundles
(`ncbi-sra-submit-configs-1-2` and `-test-1-2`), the NCBI submit bundles
(`ncbi-submit-configs-prod` and `-test-1-1`), and the
`ncbi-sra-submit-ssh-key-data-latest` SSH key.

The secret contents are read from files on the control machine under
`<inventory-repo>/<secrets_loader_base_dir>/` (default `secrets/`, resolved
relative to the private inventory repo's top-level directory), so the run
fails unless that secrets tree is present locally. Each secret's annotations
record the path each key should be materialized at inside a workflow pod.

# Citations

[1] `ansible/argo_resources.yml` — the standalone playbook entry point.
[2] `ansible/roles/argo_resources/tasks/main.yml` — the data-container secrets and the secrets_dir resolution.
[3] `ansible/roles/argo/tasks/main.yml` — Argo/Argo Events install, executor RBAC, irods-config, event source, and sensors.
