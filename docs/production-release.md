# Production Release Procedure

The end-to-end procedure for releasing the Discovery Environment into a production
environment: announcing the outage, going into maintenance mode, quiescing the services
that hold the Data Store open, pushing configuration and database updates, deploying the
release's services, and updating the nodes.

This document covers the repeatable release. Environment-specific details — where the
private inventory lives, host names, and how to get accounts provisioned — are documented
separately for CyVerse staff and are deliberately not repeated here.

For the underlying mechanics see:
- [ansible/docs/index.md](../ansible/docs/index.md) — required repositories, tool versions,
  kubeconfig generation
- [ansible/BUILD_DEPLOY.md](../ansible/BUILD_DEPLOY.md) — building images and the deploy playbooks
- [ops-runbook.md](ops-runbook.md) — day-to-day operations, rollbacks, log access

## Table of contents

- [1. Before you start](#1-before-you-start)
- [2. AWS and EKS access](#2-aws-and-eks-access)
- [3. Announce the outage and enter maintenance mode](#3-announce-the-outage-and-enter-maintenance-mode)
- [4. Quiesce the Data Store consumers](#4-quiesce-the-data-store-consumers)
- [5. Update your checkouts](#5-update-your-checkouts)
- [6. Push configuration, secrets, and database updates](#6-push-configuration-secrets-and-database-updates)
- [7. One-time migrations for the current release](#7-one-time-migrations-for-the-current-release)
- [8. Deploy the release's services](#8-deploy-the-releases-services)
- [9. Leave maintenance mode](#9-leave-maintenance-mode)
- [10. Node OS updates and reboots](#10-node-os-updates-and-reboots)

## 1. Before you start

You need two checkouts: this repository, and the private repository that holds the
environment's Ansible inventory and `group_vars`. Required tool versions are listed in
[ansible/docs/index.md](../ansible/docs/index.md) — `ansible`, `kubectl`, `helm`,
`skaffold`, `golang-migrate`, `psql`, and `k0sctl`.

All `ansible-playbook` commands below are run from the `ansible/` directory of this
repository.

### Set INVENTORY

Point it at the `inventory/` directory inside the private inventory repo for the
environment you are releasing to.

```bash
export INVENTORY=<path/to/private-inventory/inventory>
```

```fish
set -gx INVENTORY <path/to/private-inventory/inventory>
```

### Generate and set KUBECONFIG

The kubeconfig comes from `k0sctl`, run from the private inventory repo's top-level
directory with `main` up to date. Set the SSH variables for your local environment first:

```bash
export K0S_SSH_USER=<your-username>
export K0S_SSH_KEY_PATH=~/.ssh/id_rsa.pub
```

Your user needs passwordless SSH and sudo on the cluster nodes. The sudo half:

```bash
ansible k8s_nodes -i $INVENTORY -K --become -m shell -a "usermod -aG k0s $K0S_SSH_USER"
```

Then generate the kubeconfig and export it:

```bash
mkdir -p ~/.kube/
k0sctl kubeconfig > ~/.kube/prod.conf
export KUBECONFIG=~/.kube/prod.conf
```

> **Kubeconfig resolution:** `KUBECONFIG` alone does not guarantee which cluster Ansible will
> target. An inventory's `group_vars` can pin `kubeconfig` explicitly and silently win over
> your exported env var. Before any `ansible-playbook` or `kubectl` command that mutates a
> cluster, confirm both `KUBECONFIG` and the inventory agree on the same environment.
> **Deploying to production requires explicit confirmation — never default to it.**
> See `skills/resolving-the-kubeconfig/SKILL.md` for the full resolution procedure.

Set the namespace you will be working in as well; the examples below use `$NS`.

```bash
export NS=prod
```

### macOS note

Installing the required Python libraries into Homebrew's Python can be cumbersome, so it is
often easier to use the Python that ships with macOS. Install the dependencies with
`/usr/bin/pip3` and tell Ansible to use that interpreter via an extra var:

```bash
/usr/bin/pip3 install psycopg2 kubernetes

ansible-playbook -i $INVENTORY -e 'ansible_python_interpreter=/usr/bin/python3' \
  --tags=configure-services kubernetes.yml
```

## 2. AWS and EKS access

`vice-operator` is also deployed into an AWS EKS cluster. You need the `aws` command-line
tool locally and an account with access to that cluster — ask a team member with AWS
account admin access if you do not have one yet.

```bash
aws login
```

Your browser opens for the login flow; follow the instructions there.

Get the cluster's kubeconfig with the procedure in the AWS documentation:
[Creating or updating a kubeconfig file for an Amazon EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html#create-kubeconfig-automatically).
The cluster's region and name come from the sandbox inventory.

Set `SANDBOX_INVENTORY` to the top-level directory of that inventory repo:

```bash
export SANDBOX_INVENTORY=<path/to/sandbox-inventory>
```

Skip this section entirely if the release does not include a `vice-operator` update.

## 3. Announce the outage and enter maintenance mode

Announce the maintenance window in the team's maintenance announcement channel before
touching anything.

### The DE

Maintenance mode is toggled through the `maintenance-page-admin` service, which repoints the
environment's HTTPRoutes at itself. Port-forward its admin interface:

```bash
kubectl -n $NS port-forward deployment/maintenance-page-admin 4242:http
```

Open <http://localhost:4242>. You will be prompted for a username and password; these are
the `basic_auth_username` and `basic_auth_password` values in your inventory's
`group_vars`. Click the button to put the DE into maintenance. Clicking it again takes the
DE back out.

### The Subscription Portal

Toggle the `Maintenance` switch on the Subscription Portal's `/admin` page for the
environment. All developers should have admin accounts.

If the portal is *already* in maintenance mode and you are not already logged in with an
admin account, the admin page is unreachable and the switch has to be flipped in the
database instead. From a host with access to the Subscription Portal database:

```sql
UPDATE maintenance SET enabled = NOT enabled RETURNING enabled;
```

## 4. Quiesce the Data Store consumers

### Kill all running jobs

**TODO:** process still to be determined. This step is a known gap in the procedure.

### Scale down the Data Store consumers

These services hold connections to the Data Store and must be scaled to zero before it
goes offline:

- `dewey`
- `info-typer`
- `infosquito2`
- `data-info`

Record the current replica counts first — you need them to restore the services in
[step 9](#9-leave-maintenance-mode):

```bash
kubectl -n $NS get deployments dewey info-typer infosquito2 data-info
```

Then scale them down:

```bash
kubectl -n $NS scale deployments dewey info-typer infosquito2 data-info --replicas 0
```

## 5. Update your checkouts

Put both repositories on `main` and pull:

- this `deployments` repository
- the private inventory repository

Service build descriptors are committed to this repository under
`ansible/roles/services/<service>/files/<service>.json`, so pulling `deployments` is what
brings in the release's images.

## 6. Push configuration, secrets, and database updates

Render and push the service configuration secrets:

```bash
ansible-playbook -i $INVENTORY --tags=configure-services kubernetes.yml
```

Run the database migrations:

```bash
ansible-playbook -i $INVENTORY --tags=update-databases kubernetes.yml
```

`update-databases` runs the migrations for every database the inventory enables — the DE
database always, plus Grouper, QMS, Harbor, Keycloak, the portal, and Grafana where the
corresponding inventory flag is set. Migrations need `migrate` (from `golang-migrate`) on
your `PATH`.

## 7. One-time migrations for the current release

> **This section is transient.** It covers cutover steps that run once, for a specific
> release, and is deleted once that release has shipped to every environment. If the
> release you are deploying does not include these migrations, skip to
> [step 8](#8-deploy-the-releases-services).

### Move the notifications database into the DE database

The migrations that create the new schema in the `de` database run as part of
[step 6](#6-push-configuration-secrets-and-database-updates) — this is a reminder to go
back and run them if you skipped ahead.

Deploy the `apps` service first. It contains the code that works with the new schema;
job-status notifications from the previous version raise errors against it.

```bash
ansible-playbook -i $INVENTORY --tags=apps deploy_it.yml
```

Run the merge. It dumps the standalone notifications database and loads it into the `de`
database, transforming the data to fit the new table layout.

```bash
ansible-playbook -i $INVENTORY notifications_db_merge.yml
```

Deploy the `notifications` service. Doing it now avoids orphaning data — the old version
would write bare usernames into the `public.users` table.

```bash
ansible-playbook -i $INVENTORY --tags=notifications deploy_it.yml
```

Run the merge again to catch anything written between the two deploys.

```bash
ansible-playbook -i $INVENTORY notifications_db_merge.yml
```

### Deploy the consolidated job-status service

This deploys `job-status`, cleans out the retired `job-status-recorder`,
`job-status-listener`, and `job-status-to-apps-adapter` services, and reconfigures batch
analyses to send updates to `job-status`.

```bash
ansible-playbook -i $INVENTORY --tags=job-status deploy_it.yml
ansible-playbook -i $INVENTORY --tags=networking,ingress,argo kubernetes.yml
ansible-playbook -i $INVENTORY --tags=app-exposer deploy_it.yml
```

The `app-exposer` deploy also removes the retired `timelord` and `vice-status-listener`
resources, whose work moved into `app-exposer` and `vice-operator` respectively. Neither
is a deployable service any more, so neither has a tag of its own.

### Deploy the consolidated subscriptions service

`subscriptions` now incorporates `qms`.

```bash
# Deploy the new subscriptions service
ansible-playbook -i $INVENTORY --tags=subscriptions deploy_it.yml

# Point terrain at subscriptions instead of qms; also picks up any terrain updates
ansible-playbook -i $INVENTORY --tags=terrain deploy_it.yml

# Clean out the old qms service
ansible-playbook -i $INVENTORY qms_cleanup.yml
```

## 8. Deploy the release's services

### Find the services in the release

A release is the set of git refs recorded across the service build descriptors. Search
them for the release tag:

```bash
rg v2026.09.01 ansible/roles/services/*/files/*.json
```

For example:

```
ansible/roles/services/sonora/files/sonora.json
1:{"builds":[{"imageName":"harbor.cyverse.org/de/sonora","tag":"harbor.cyverse.org/de/sonora:v2026.09.01-rc02@sha256:f65c3d..."}]}

ansible/roles/services/app-exposer/files/app-exposer.json
1:{"builds":[{"imageName":"harbor.cyverse.org/de/app-exposer","tag":"harbor.cyverse.org/de/app-exposer:v2026.09.01-rc01@sha256:67ae01..."}]}
```

That release contains `sonora` and `app-exposer`.

> Deploys read descriptors from `build_json_dir`, which defaults to each service role's own
> `files/` directory. An inventory may override it to read descriptors from somewhere else.
> If a deploy picks up an image you did not expect, check `build_json_dir` in your
> inventory's `group_vars`.

### Deploy them

Every service is a tag on `deploy_it.yml`. Deploy one:

```bash
ansible-playbook -i $INVENTORY --tags=sonora deploy_it.yml
```

Or several at once:

```bash
ansible-playbook -i $INVENTORY --tags=sonora,app-exposer deploy_it.yml
```

Listing several tags does not control the order they run in — services deploy in the fixed
order declared in `deploy_it.yml`.

### Deploy vice-operator to the EKS cluster

With the EKS kubeconfig and AWS login from [step 2](#2-aws-and-eks-access) in place:

```bash
KUBECONFIG=<path/to/eks/kubeconfig> \
  ansible-playbook -i $SANDBOX_INVENTORY --tags=vice-operator vice-operator-eks.yml
```

### Deploying everything

Not normally part of a release. This is for a fresh install, or for recovering from
something catastrophic.

```bash
ansible-playbook -i $INVENTORY --tags=deploy-all-services kubernetes.yml
ansible-playbook -i $INVENTORY deploy_it.yml
```

## 9. Leave maintenance mode

Restore the Data Store consumers to the replica counts you recorded in
[step 4](#4-quiesce-the-data-store-consumers). Deploying a service resets its replicas to
whatever its manifest declares, so check the counts again before scaling:

```bash
kubectl -n $NS get deployments dewey info-typer infosquito2 data-info
kubectl -n $NS scale deployment/<service> --replicas <recorded-count>
```

Confirm the DE is healthy — see [ops-runbook.md](ops-runbook.md) §1 — then take both the
DE and the Subscription Portal back out of maintenance mode by reversing
[step 3](#3-announce-the-outage-and-enter-maintenance-mode), and announce that the
maintenance window is over.

## 10. Node OS updates and reboots

System updates run in at least two stages: pulling the updates down, and restarting the
hosts. They are separate playbooks so updates can be staged ahead of time and the reboots
performed later, which speeds up release day. Rebooting drains each host and uncordons it
after it comes back Ready — see [ops-runbook.md](ops-runbook.md) §8 for what draining
costs running VICE apps.

Update the packages on the nodes:

```bash
ansible-playbook -i $INVENTORY -K --become update_nodes.yml
```

If the Copy Fail mitigation needs to be removed:

```bash
ansible-playbook -i $INVENTORY -K --become uninstall_disable_af_alg.yml
```

Reboot the nodes:

```bash
ansible-playbook -i $INVENTORY -K --become reboot_nodes.yml
```
