---
type: Runbook
title: Importing Groups from Grouper
description: Running the grouper-import tool to copy DE group data out of Grouper into the permissions schema, and keeping it in step during the migration.
resource: /ansible/grouper_import.yml
tags: [grouper, groups, migration, import, cronjob]
timestamp: 2026-08-05T00:00:00Z
---

`grouper-import` copies DE group data out of [Grouper](/infrastructure/grouper.md)
into the `permissions` schema that the [groups](/services/groups.md) and
[permissions](/services/permissions.md) services read. It ships in the groups
image and runs as a Job; the entrypoint is the service, so the Job overrides the
command.

It is **convergent, not merely idempotent**: it reconciles groups, membership,
and permission grants to Grouper's current state — including removals — rather
than accumulating. Running it repeatedly is expected, and a second run against
unchanged Grouper reports zeros.

## Running it once

```
ansible-playbook -i $INVENTORY grouper_import.yml -e dry_run=true
ansible-playbook -i $INVENTORY grouper_import.yml
```

The playbook runs the Job, waits for it, prints the importer's report, and fails
if the Job did not succeed. `-e import_phase=groups` imports groups and
membership only; `-e import_phase=permissions` does the privilege grants, which
go through the permissions HTTP API rather than SQL.

**Read the report, not just the exit status.** It names the groups that
disappeared from Grouper, the member identifiers it had to trim, the privileges
it could not translate, and whether the effective-membership closure matches
Grouper's own expansion. A clean run prints zeros; a run that reports nothing is
a run that did nothing. The importer exits nonzero when its own verification
fails — a closure mismatch or members that failed to migrate — so automation
sees those as failures, but the *informational* lists (groups gone from
Grouper, groups created natively) still change nothing about the exit status
and are only visible in the report.

## Keeping it in step

The role also deploys a `grouper-import` CronJob, created **suspended**. Resume
it once the permissions service is reading group data from this database:

```
kubectl -n $NAMESPACE patch cronjob grouper-import -p '{"spec":{"suspend":false}}'
```

This matters for as long as Grouper stays authoritative. terrain and apps still
write group changes there, and those changes are invisible to the permissions
service until the next import — a user added to a collaborator list simply does
not get access. Suspend it again once terrain, apps, group-propagator, and
Sonora have cut over.

## Guards

- **It refuses to run once `group_data_source` says this database is
  authoritative.** After cutover a reconcile would delete group data created
  natively, so there is deliberately no override flag: setting the marker back to
  `grouper` is the explicit, attributed act that re-enables it.
- **It never deletes groups.** A group that vanished from Grouper is reported,
  not removed — deleting one cascades away every permission granted to it.
- **It takes an advisory lock**, so two runs cannot interleave.
- **The environment prefix is required.** A wider scope pulls in another
  environment's `de-users`, which collides with this one on
  `(group_type, owner, name)`.
- **An unparsable group name aborts the run**, rather than being skipped into a
  clean-looking import with groups missing.

## Testing it against a local cluster

A freshly deployed local DE has one DE group (`users:de-users`) and two LDAP
subjects. That is enough to prove the importer runs and nothing about whether it
is correct — no nesting, one group type, no privileges worth mapping.

`ansible/scripts/seed-local-grouper.py` creates a dataset shaped like
production's: every group type with owners, a **two-level nesting chain**, a
member reachable by two paths, and the privilege vocabulary including
`GrouperAll`. It goes through iplant-groups rather than the Grouper database, so
the groups are formed exactly the way the DE forms them, and it is idempotent.

```bash
export LDAP_ROOT_PW=...        # ldap_root_pw from the local inventory
KUBECONFIG=~/.kube/local-admin.conf ansible/scripts/seed-local-grouper.py
kubectl -n de create job --from=cronjob/grouper-import gi-1
kubectl -n de logs job/gi-1
```

The two structures that matter are easy to lose and hard to notice missing:

- **`Field Team` → `Genomics Lab` → `msmith:default`** puts `lchen` in Field
  Team at *depth 2*. An expansion that follows only one hop drops that member
  and still produces a plausible-looking result.
- **`lchen` reaches `Imaging` both directly and through a nested group**, so
  `grouper_memberships_v` returns that pair twice. The view is not a set, and an
  importer that assumes it is will double-count.

What to look for in the report: `effective membership vs Grouper: N expected, 0
missing, 0 unexpected` is the closure check, and it is the single most
informative line. Then re-run it — a second run must report zeros across
created/updated/added/removed. To check it is *convergent* rather than merely
idempotent, change something in Grouper (remove a member, revoke a privilege,
rename a group) and re-run: the changes must be reflected, not accumulated. A
rename in particular must come back as `1 updated` with nothing reported under
"groups in the database but no longer in Grouper", which is what shows the
importer matches on the Grouper UUID rather than the name.

Note the seeder asserts its own dataset, so running it after such an experiment
puts the removed member and revoked privilege back; re-import afterwards to
bring the permissions database into line.

## Configuration

Credentials come from the `grouper-import-configs` secret as `GROUPS_IMPORT_*`
environment variables, so they never appear in a command line. The role renders
it from the same `grouper_db_*`, `dbms_connection_*`, and `groups_user_suffix`
variables the services use; the importer and the groups service must agree, since
the importer writes membership through the service's own store.

# Citations

[1] `ansible/grouper_import.yml` — the one-off Job, its wait, and the report.
[2] `ansible/roles/services/groups/tasks/import.yml` — credentials secret and CronJob deploy.
[3] `ansible/roles/services/groups/templates/k8s/grouper-import.yml.j2` — the suspended CronJob.
[4] `ansible/roles/services/groups/defaults/main.yml` — schedule and suspend defaults.
[5] `ansible/scripts/seed-local-grouper.py` — the local test dataset.
