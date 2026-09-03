---
type: Service
title: data-info
description: HTTP API for data-store operations — file and folder metadata, permissions, path lists, and anonymous-access URLs backed by iRODS.
resource: /ansible/roles/services/data-info
tags: [data, irods, icat, files, de]
timestamp: 2026-08-18T00:00:00Z
---

data-info is the DE's data-store API. It is a JVM service (the pod sets
`JAVA_TOOL_OPTIONS`) that talks directly to [iRODS](/infrastructure/irods.md)
as `irods_user` and queries the ICAT [PostgreSQL](/infrastructure/postgresql.md)
database (`icat_host`/`ICAT`). It builds anonymous-access URLs against the
iRODS WebDAV `dav-anon` endpoint (`irods_webdav_anon_uri`, with a fallback to
`{{ de_base_uri }}/anon-files`) and [kifshare](/services/kifshare.md)-style
download links under `{{ de_base_uri }}/dl`. It calls the
[async-tasks](/services/async-tasks.md), [notifications](/services/notifications.md),
and [metadata](/services/metadata.md) services, and connects to the DE
[RabbitMQ](/infrastructure/rabbitmq.md) vhost via `de_amqp_*`.

- Source: [cyverse-de/data-info](https://github.com/cyverse-de/data-info); image `harbor.cyverse.org/de/data-info` from [Harbor](/infrastructure/harbor.md), pinned by digest in the build descriptor.
- Config: `data-info.properties.j2` is templated into the `data-info-configs` secret and mounted at `/etc/iplant/de/data-info.properties`. Notable vars: `irods_*` (host, zone, admin users, perms filter), `icat_*`, `de_amqp_*`, `baseurls_*`, `de_base_uri`.
- Runtime: 2 replicas by default (`data_info_replicas`) with required pod anti-affinity; listens on port 60000; OpenTelemetry tracing to [Jaeger](/infrastructure/jaeger.md) is wired via the `configs` secret.

Deploy with `ansible-playbook -i $INVENTORY deploy_it.yml --tags data-info` —
see [Building and Deploying Services](/playbooks/build-and-deploy.md).

## Sharing skips when the recipient already has the permission via a group

One trap worth knowing, because it looks like a successful share that quietly
does nothing. Before granting access, data-info checks whether the recipient
already holds the requested permission, and skips the share if they do. That
check reads the recipient's **aggregated** permission — clj-jargon's
`permission-for` takes the maximum across every ACL that applies, including the
ones they inherit through group membership — but the share it skips would have
written a **direct** ACL on the object.

The two are not the same thing, and the DE routinely puts them out of step.
Every account belongs to `public`, and home directories usually carry a
`public` read ACL that new children inherit. So sharing anything under a home
directory with another user **at read** finds "they already have read", skips,
and writes no ACL row. The request returns success and the UI raises its
success notification, but the recipient never appears in the list of people the
item is shared with — that list shows direct ACLs. Sharing the same user at
`write` or `own` works and shows up immediately, because the aggregated
permission no longer equals what was asked for.

The same asymmetry explains why re-sharing usually looks fine: once a direct
ACL exists, a repeat share at the same level also skips, but the row is already
there, so nothing looks wrong. And lowering someone from `own` to `read`
applies, because `own` does not equal `read` — it rewrites the existing row
rather than skipping.

The missing row matters beyond the display. A skipped share is never persisted
as an ACL, so the access rests entirely on the group membership that suppressed
it. If that membership changes, the sharing silently disappears, and there is
no record that anyone ever shared the item.

This is long-standing behavior, not a regression. It affects both
`PUT /data/:data-id/permissions/:share-with/:permission` and the bulk
`POST /sharer`, since both route through the same guard. The bulk endpoint at
least reports `"reason": "already-shared"` on the skipped entry, which is the
quickest way to confirm you are looking at this and not something else:

```bash
# skipped: recipient already has read via public
curl -s -X POST "$DATA_INFO/sharer?user=$OWNER" -H 'Content-Type: application/json' \
  -d '{"sharing":[{"user":"'$RECIPIENT'","paths":[{"path":"'$PATH'","permission":"read"}]}]}'

# ground truth — direct ACLs only
curl -s -X POST "$DATA_INFO/permissions-gatherer?user=$OWNER" \
  -H 'Content-Type: application/json' -d '{"paths":["'$PATH'"]}'
```

Note that statting the path as the recipient is **not** a valid check: it
reports the aggregated permission, so it returns `read` whether the share
landed or not.

# Citations

1. `ansible/roles/services/data-info/templates/data-info.properties.j2` — iRODS/ICAT/AMQP config, anon-files mappings, dependent service URLs.
2. `ansible/roles/services/data-info/files/data-info.json` — pinned image name and digest.
3. `ansible/roles/services/data-info/templates/k8s/data-info.yml.j2` — Deployment/Service, port 60000, JAVA_TOOL_OPTIONS, OTEL env.
4. `ansible/roles/services/data-info/tasks/main.yml` — creates the `data-info-configs` secret, then runs deploy-service.
5. [`data_info/services/sharing.clj`](https://github.com/cyverse-de/data-info/blob/main/src/data_info/services/sharing.clj) — `share-path` guards on `shared?`, which compares the requested permission against `permission-for`.
6. [`clj-jargon permissions.clj`](https://github.com/cyverse-de/clj-jargon/blob/master/src/clj_jargon/permissions.clj) — `permission-for` returns the aggregated (group-inclusive) permission; `list-user-perm`, behind `permissions-gatherer`, returns direct ACLs.
