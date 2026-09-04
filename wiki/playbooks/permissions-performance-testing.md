---
type: Runbook
title: Permissions Performance Testing
description: Building a synthetic production-scale dataset in the permissions schema and measuring the group-expansion query paths against it.
resource: /ansible/scripts/synthesize-perf-dataset.sql
tags: [permissions, groups, postgresql, performance, benchmark]
timestamp: 2026-08-05T00:00:00Z
---

`ansible/scripts/synthesize-perf-dataset.sql` builds a dataset in the
[permissions](/services/permissions.md) schema at production's size and shape,
and `ansible/scripts/benchmark-permissions-lookup.sql` measures the query paths
against it. Together they answer "how does the
[groups](/services/groups.md) replacement perform at scale" without copying real
user data onto a development machine.

```
psql -h localhost -p 15432 -U de -d de -v confirm=yes -f synthesize-perf-dataset.sql
psql -h localhost -p 15432 -U de -d de -f benchmark-permissions-lookup.sql
```

`-v scale=0.1` builds a tenth of production for a quick check. A full build takes
about 45 seconds.

**Never run either against QA or production.** The generator writes ~1.5M rows
and deletes anything already matching its markers. It refuses to start without
`-v confirm=yes`.

## What it generates

Everything is marked — user subjects `perfuser*`, groups and resources `perf-*`
— so re-runs replace the dataset rather than adding to it, and cleanup can never
match a row the script did not create.

| | Synthetic | Production |
| --- | --- | --- |
| groups | 2,593 | 2,583 |
| subjects | 47,353 | ~47,300 |
| direct memberships | 55,120 | 54,038 |
| nested memberships | 165 | ~152 |
| effective members (closure) | 55,646 | 54,467 |
| resources | 1,493,509 | 1,490,909 |
| permissions | 1,505,524 | 1,532,070 |
| benchmark subject reaches | 4,344 | 4,341 |

Three properties matter more than the row counts, and a generator that got them
wrong would produce a reassuring but meaningless benchmark:

- **`de-users` holds essentially every user.** One group with ~44,600 members is
  what makes an expansion expensive. A dataset with membership spread evenly has
  the same row count and none of the cost.
- **Ownership is skewed, not uniform.** Resource ownership is drawn from a cubed
  uniform, giving a long tail (max ~19k, median ~18 permissions per subject).
  Uniform statistics would let the planner make choices it cannot make in
  production.
- **Nesting is disjoint, not a chain.** Chaining consecutive groups makes each
  one absorb the whole tail below it; an early version did this and produced a
  closure of 102,082 against production's 54,467, nearly doubling the apparent
  cost of every lookup.

## Group resources are named by the group's ID

A group is also a resource, and that resource's name is the group's **external
32-hex id** — not its name, and not anything derived from it. That is the value
the [groups](/services/groups.md) service passes to the permissions service when
it authorizes a request, so a resource named any other way authorizes nothing
and the group's own owner gets a 403 on it. An early version of the generator
named them `perf-grp-<n>` and every synthetic group was unadministrable.

Public teams and communities carry a `read` grant to `GrouperAll`, and that
grant **does** confer read access — see
[how a group is marked public](/services/groups.md). Checking
`grouper_memberships_v` is misleading here and briefly led this page to claim
the opposite: `GrouperAll` never appears there because that view is *membership*,
while `viewers`/`readers` are privilege fields in `grouper_memberships_all_v`,
which Grouper's privilege engine resolves as everyone.

A dataset without those grants makes every group private, so the browse-then-open
flow cannot be exercised at all. The generator marks a third of teams and every
community public, against production's ~183 and ~55.

## What it measured

| Path | Result |
| --- | --- |
| A. `lookup=true`, inlined expansion | **5.0 ms**, nested-loop index scans, cost 80 |
| B. `lookup=true`, literal array (the old form) | 4.9 ms, cost 2,554 |
| C. `lookup=false` | 0.03 ms |
| E. `expand_groups=true` on a de-users resource | **58 ms**, capped at 10,001 rows |
| D. `recompute_group_closure` for de-users | **427 ms** |

Two of these are worth carrying forward. **Every membership write to de-users
pays 427 ms** for the closure recomputation, because the function deletes and
rebuilds that group's rows wholesale; the cost is proportional to the group's
membership, and de-users is the largest group in the deployment. And the
capped expansion at 58 ms is the cap earning its place — without
`max_expanded_subjects` the same query expands to all ~44,600 members.

**The synthetic data does not reproduce the old form's regression.** Measured
against a restored copy of production, the inlined expansion was ~2.6x faster
than the literal-array form (19 ms against 49 ms, costs 478 against 27,581).
Here the two are within noise of each other, because the planner chooses a
nested loop for both rather than falling back to a parallel scan. So these
numbers confirm the shipped query is fast at production scale; they do **not**
independently confirm the improvement over what it replaced. The difference
most likely lies in planner statistics that synthetic data does not reproduce,
or in the reconstruction of a query that has since been deleted. Treat the
production measurement as the authority on the comparison.

Note also that the planner underestimates both forms badly — 65 estimated
against 4,344 actual for the inlined shape. It picks a good plan anyway at this
size, but the estimate is not why.

## A missing index

The schema indexes `permissions (subject_id, resource_id)` and nothing on
`resource_id` alone, so the foreign-key check behind `ON DELETE CASCADE` from
`resources` scans the whole permissions table once per deleted resource.
Deleting this dataset's 1.49M resources **did not finish in ten minutes**; with
`permissions_resource_id_idx` in place it took **3.7 seconds**. Any query
filtering permissions by resource alone takes a sequential scan for the same
reason.

The generator creates the index so its own cleanup terminates. It predates the
groups work — `permissions.permissions` comes from migration `000021` — so this
is a standing schema gap rather than a regression, and it belongs in a migration
rather than in a test script.

# Citations

[1] `ansible/scripts/synthesize-perf-dataset.sql` — the generator, its markers, and the production figures it targets.
[2] `ansible/scripts/benchmark-permissions-lookup.sql` — the query shapes and the expansion path.
