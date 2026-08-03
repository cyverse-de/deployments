---
type: Runbook
title: Deploying a Full DE Environment
description: How to deploy a complete Discovery Environment with kubernetes.yml, from kubeconfig generation through database setup and service rollout.
resource: /ansible/kubernetes.yml
tags: [deploy, kubernetes, ansible, k0s, environment]
timestamp: 2026-07-31T12:00:00Z
---

`kubernetes.yml` is the top-level playbook for standing up and maintaining a
full DE environment. You need the `deployments` repo, the private inventory
repo, and (only if the inventory overrides `build_json_dir`) a `de-releases`
checkout. Required tools: `ansible`, `kubectl` >= 1.29, `helm` >= 3.16,
`skaffold`, `golang-migrate` >= 4.18, `psql` >= 14, and `k0sctl`.

## Get a kubeconfig

The cluster runs [k0s](/infrastructure/kubernetes-cluster.md), and the
kubeconfig comes from `k0sctl`. From the private inventory repo's top-level
directory (with `main` up to date), set `K0S_SSH_USER` and
`K0S_SSH_KEY_PATH`, make sure your user has passwordless SSH and sudo on the
cluster nodes (`usermod -aG k0s $K0S_SSH_USER`), then:

```bash
k0sctl kubeconfig > ~/.kube/prod.conf
export KUBECONFIG=~/.kube/prod.conf
```

The `kubeconfig` Ansible var is what actually selects the cluster. It defaults
to the `KUBECONFIG` environment variable, but an inventory may pin it in
group_vars — and a group_vars value wins over the environment, silently. Where
the two disagree, the export is ignored and the inventory decides.

That only holds for tasks that use the var. A cluster-touching task with
neither `environment: KUBECONFIG: "{{ kubeconfig }}"` nor a `kubeconfig`
module argument falls through to the ambient environment, so it acts on
whichever cluster the operator's shell last pointed at while the rest of the
play works on the intended one — a failure mode with no symptom until the wrong
cluster changes. Any new task that talks to a cluster needs one or the other;
setting it on the enclosing `block` is the usual form.

## Deployment sequence

Run the playbook with tags — an untagged run works through everything in
order but is slow and resource-hungry. The core sequence is:

```bash
export INVENTORY=<path/to/private-inventory/inventory/>

ansible-playbook -i $INVENTORY --tags=setup-databases kubernetes.yml
ansible-playbook -i $INVENTORY --tags=configure-services kubernetes.yml
ansible-playbook -i $INVENTORY --tags=deploy-all-services kubernetes.yml
```

`setup-databases` creates and migrates the databases via `postgresql_init`
(migrations need `migrate` on your PATH); `configure-services` renders the
shared `configs` secret and loads secrets; `deploy-all-services` runs every
role under `roles/services/`. Deploys read each service's build descriptor
(`<service>.json`) from `build_json_dir`, which defaults to the service role's
`files/` directory; inventories may override it (QA points at a sibling
`de-releases/builds` checkout). To build images first, or to deploy a subset
afterwards with `deploy_it.yml`, see
[Building and Deploying Services](/playbooks/build-and-deploy.md).

`kubernetes.yml` assumes it owns the cluster and the nodes: it runs `k0sctl`,
reconfigures each node over SSH, and installs PostgreSQL on a database host. To
deploy onto a cluster that already exists — a single node on a workstation, for
instance — use `local.yml` instead, which does everything in-cluster and adds
the roles that stand in for the out-of-cluster pieces. See
[Local Single-Node Deployment](/playbooks/local-single-node-deployment.md).

## Major tags

* Node prep: `prep-nodes`, `add-nodes`, `firewall`, `timezone`,
  `install-gpu-drivers`, `nvidia-container-toolkit`, `irods-csi-driver`
* Cluster and storage: `create-cluster`, `haproxy` / `ui-haproxy`,
  `cert-manager`, `cert-issuers`, `longhorn`, `openebs`
* Third-party subsystems: `de-reqs`, `argo`, `ingress-nginx`, `traefik`,
  `opensearch`, `grouper`, `image-cache`, `ingress`, `networking`
* Opt-in only (skipped unless the tag is passed explicitly): `harbor`,
  `keycloak`, `jaeger`, `grafana`
* Databases and services: `install-postgres`, `setup-databases`,
  `configure-services`, `deploy-all-services`, `deploy-single-service`
  (with `-e project=<service>`), `cronjobs`

Adding a node uses `--tags add-nodes --limit <node-name>` with
`--ask-become-pass`.

# Citations

[1] `ansible/kubernetes.yml` — the playbook: plays, roles, and tag wiring described here.
[2] `ansible/docs/index.md` — source for required tools, kubeconfig generation, and the tag sequence.
[3] `ansible/README.md` — database initialization table and per-subsystem tag notes.
