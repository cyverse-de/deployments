---
type: Runbook
title: Production Release Procedure
description: The end-to-end production release run — maintenance mode, quiescing Data Store consumers, config and database updates, service deploys, and node updates.
resource: /docs/production-release.md
tags: [release, production, maintenance, deploy, ansible]
timestamp: 2026-09-03T00:00:00Z
---

A release is the set of git refs recorded across every service's build
descriptor (see [Building and Deploying Services](/playbooks/build-and-deploy.md)).
Releasing one into production is a maintenance-window procedure: the DE goes
offline, the services that hold the Data Store open are scaled to zero,
configuration and database updates land, the release's services deploy, and the
nodes get their OS updates.

This page is the shape of the procedure. The step-by-step commands live in
`docs/production-release.md`. Environment-specific details — where the private
inventory lives, host names, account provisioning — are documented separately
for CyVerse staff.

## Before the window

Two checkouts: this repo and the private inventory repo. `INVENTORY` points at
the latter's `inventory/` directory; `KUBECONFIG` comes from `k0sctl` run from
its top-level directory. Tool versions are in
[Deploying a Full DE Environment](/playbooks/full-deployment.md), which also
explains why an inventory's `group_vars` can pin `kubeconfig` and silently beat
your exported environment variable — confirm both agree on the same environment
before running anything that mutates a cluster.

If the release includes a `vice-operator` update, it also deploys into an AWS
EKS cluster via `vice-operator-eks.yml`, which needs the `aws` CLI, an account
with access to that cluster, and its kubeconfig.

## The sequence

1. **Announce and enter maintenance.** The DE's maintenance mode is toggled
   through [maintenance-page](/services/maintenance-page.md), reached by
   port-forwarding its `http` port and authenticating with the
   `basic_auth_username` / `basic_auth_password` values from the inventory. The
   Subscription Portal has its own switch on its `/admin` page, with a database
   fallback for when the portal is already in maintenance and you are not
   already logged in as an admin.
2. **Quiesce the Data Store consumers.** `dewey`, `info-typer`, `infosquito2`,
   and `data-info` scale to zero. Record their replica counts first — nothing
   else remembers them.
3. **Update the checkouts.** Build descriptors are committed to this repo under
   `ansible/roles/services/<service>/files/`, so pulling `deployments` is what
   brings in the release's images.
4. **Push configuration and database updates.** `kubernetes.yml` with
   `--tags=configure-services`, then `--tags=update-databases`. The latter runs
   `postgresql_init`'s migrations for the DE database plus whichever of
   Grouper, QMS, Harbor, [Keycloak](/infrastructure/keycloak.md), the portal,
   and Grafana the inventory enables — see [PostgreSQL](/infrastructure/postgresql.md).
5. **Run any one-time migrations.** Cutover steps that belong to a specific
   release rather than to every release, such as
   [Merging the Notifications Database into DE](/playbooks/notifications-db-merge.md)
   or [Cutting Group Management Over from Grouper](/playbooks/grouper-cutover.md).
   `docs/production-release.md` carries these in a section that is deleted once
   the release has shipped everywhere.
6. **Deploy the release's services.** Find them by searching the descriptors for
   the release tag, then deploy with `deploy_it.yml --tags <service>`. Every
   service is a tag on that playbook.
7. **Leave maintenance.** Restore the replica counts from step 2 — a deploy
   resets replicas to whatever the manifest declares — verify health per the
   [General Operations Runbook](/playbooks/ops-runbook.md), then clear both
   maintenance toggles.
8. **Update and reboot the nodes.** `update_nodes.yml` then `reboot_nodes.yml`,
   split so updates can be staged ahead of release day. See
   [Node OS Updates and Rolling Reboots](/playbooks/node-maintenance.md).

## Killing running jobs

The source procedure lists killing all running analyses before the Data Store
goes offline, with the process still to be determined. It remains an open gap
rather than a step anyone has written down.

## Deploying a single service

There is no `deploy_service.yml`. Single-service deploys go through
`deploy_it.yml --tags <service>`; `kubernetes.yml --tags=deploy-single-service
-e project=<service>` does the same thing from the full-environment playbook.
Listing several tags does not control ordering — services deploy in the fixed
order declared in `deploy_it.yml`.

`timelord` and `vice-status-listener` are no longer deployable and have no
tags; their work moved into `app-exposer` and `vice-operator`, and deploying
`app-exposer` removes what they left behind.

# Citations

[1] `docs/production-release.md` — the step-by-step procedure this page summarizes.
[2] `ansible/kubernetes.yml` — the `configure-services`, `update-databases`, `deploy-single-service`, and `deploy-all-services` tags.
[3] `ansible/deploy_it.yml` — the per-service tag list and its fixed deploy order.
[4] `ansible/vice-operator-eks.yml` — the EKS-side vice-operator deploy.
[5] `ansible/roles/postgresql_init/tasks/main.yml` — what `update-databases` migrates.
