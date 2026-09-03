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
> release, and each is deleted once it has shipped to every environment. If the release
> you are deploying does not include the migration below, skip to
> [step 8](#8-deploy-the-releases-services).

### Move group management off Grouper

Switches the DE's group data — collaborator lists, teams, communities, and the
`de-users`/`workshop-users` system groups — from Grouper to the `permissions` schema of
the DE database, served by the new `groups` service. Afterwards terrain, apps, and
group-propagator do not talk to Grouper or `iplant-groups` at all.

Everything ships in this one window. Nothing runs against live traffic partway through,
so there is no soak between the `permissions` deploy and the rest, and the
`grouper-import` CronJob stays suspended throughout.

The order below is load-bearing. The data source marker must flip *after* the import and
*before* terrain is pointed at the new backend, and the community tag rewrite must run
*after* the import and *before* the new `apps` image starts writing tags of its own.

#### Ahead of the maintenance day

The group tables arrive with the migrations in
[step 6](#6-push-configuration-secrets-and-database-updates), which is safe to run early —
nothing reads them until the window, and the dry runs below need them to exist.

Deploy `groups` early too. It creates the `grouper-import-configs` secret the import Job
needs, and the `grouper-import` CronJob, which ships suspended and stays that way.

```bash
ansible-playbook -i $INVENTORY --tags=groups deploy_it.yml
```

Then dry-run the import, repeatedly, until the report is boring — no unparsed names, no
unexplained collisions, and orphan lists you have already read. A dry run reads Grouper
and writes nothing.

```bash
ansible-playbook -i $INVENTORY grouper_import.yml -e dry_run=true
ansible-playbook -i $INVENTORY grouper_cutover.yml --tags=preflight
```

The `preflight` tags are read-only and answer most of what could go wrong on the day.

Do **not** set `terrain_groups_backend` in the inventory ahead of time. It defaults to
`iplant-groups`; setting it early means an unrelated `configure-services` run flips
terrain before any of the steps below have happened.

#### In the window

Deploy the two services the rest depends on. The `permissions` deploy is the one that can
take the DE down — every permission check goes through it — so the verification below is
not optional.

```bash
ansible-playbook -i $INVENTORY --tags=groups,permissions deploy_it.yml
```

Run the real import. Grouper's groups, memberships, and privileges land in the DE database
here. Read the report: the closure line must be `0 missing, 0 unexpected`, and both
"groups no longer in Grouper" and "groups created natively" should be none.

```bash
ansible-playbook -i $INVENTORY grouper_import.yml
```

Rewrite each app's community tag from the community's Grouper name to its ID. It must run
after the import, whose recorded `legacy_name` values are the mapping. Orphan values are
reported and deliberately left in place.

```bash
ansible-playbook -i $INVENTORY community_tags.yml -e dry_run=true
ansible-playbook -i $INVENTORY community_tags.yml
```

Flip the data source marker. This checks its preconditions, moves the marker, and confirms
it took; from here the importer refuses to run, because reconciling to Grouper would delete
anything created natively.

```bash
ansible-playbook -i $INVENTORY grouper_cutover.yml
```

Finally set `terrain_groups_backend: groups` in the inventory's `group_vars` and deploy the
rest of the cutover set:

```bash
ansible-playbook -i $INVENTORY --tags=configure-services kubernetes.yml
ansible-playbook -i $INVENTORY --tags=terrain,apps,group-propagator,sonora deploy_it.yml
```

Check that the rendered config actually carries the toggle before trusting the terrain
deploy — a rollout against a stale secret looks identical to one that worked, and this bit
the rehearsal:

```bash
kubectl -n $NS get secret terrain-configs -o jsonpath='{.data.terrain\.properties}' \
  | base64 -d | grep groups.backend
```

Sonora is a browser app, so its deploy is not atomic: users keep stale bundles as long as
their tabs live. That is expected — `apps` accepts both the old and new community-tag
request shapes.

#### Verify before leaving maintenance mode

- App and analysis listings, and app sharing, behave normally for a test account. These
  exercise the permissions service's new in-database group expansion on every request.
- A user sees apps shared with a group they belong to.
- A community's `display_name` from terrain is its short name (`Imaging`), not a colon
  path (`iplant:de:prod:communities:Imaging`).
- Create a test team through terrain, add a member, list members, delete it. The group
  appears in `permissions.groups`, and **nothing** new appears in Grouper.
- An app tagged into a community before the cutover still appears in that listing.
- group-propagator logs `Updated group ... -> @grouper-<id>`; the iRODS group names keep
  that form because group IDs are preserved.
- The `groups` status endpoint reports `{"database":true,"keycloak":true}`.

**Leave the Grouper deployments running.** They take no writes from the DE any more, but
they are the rollback path for the soak week.

#### Rolling back

While the DE is still in maintenance this is free: no users have access, so nothing has
been written natively. Afterwards it discards group changes users made since the window —
the trade the marker row exists to make explicit.

Redeploy first, then re-enable the importer; doing it the other way round means the DE and
the importer fight over the same rows.

1. Set `terrain_groups_backend: iplant-groups`, re-run `configure-services`, and redeploy
   the previous terrain, apps, group-propagator, and sonora images.
2. Hand group data back to Grouper:

   ```bash
   ansible-playbook -i $INVENTORY grouper_cutover.yml --tags=rollback
   ```

3. Run `grouper_import.yml` to reconcile the database back to Grouper's state.
4. Decide what happens to `permissions`. Its Grouper-backed code path was deleted rather
   than toggled, so rolling it back means redeploying its previous image — which is why
   its `grouperdb` config section has to stay in the deployed config until the rollback
   window closes. If it instead stays on the new image while the rest of the DE runs
   against Grouper, unsuspend the `grouper-import` CronJob: permission checks read group
   data from the database, and without scheduled imports every group change made through
   Grouper-backed terrain is invisible until the next import.

#### After the soak

Once production has run for at least a week with no Grouper-shaped problems, scale the
Grouper stack to zero. Record the replica counts first, the same way
[step 4](#4-quiesce-the-data-store-consumers) does:

```bash
kubectl -n $NS get deployments grouper-ws grouper-loader iplant-groups
kubectl -n $NS scale deployments grouper-ws grouper-loader iplant-groups --replicas 0
```

Then re-check the verification list and sweep the terrain, apps, permissions, groups, and
group-propagator logs for attempted Grouper or `iplant-groups` connections. The only
acceptable mention is terrain's startup config echo of the unused
`terrain.iplant-groups.base-url` key. Removing the Grouper deployments, databases, and
roles from this repository is follow-up work for a later release.

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
