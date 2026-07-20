---
type: Service
title: kifshare
description: Public download page for files shared from the data store via iRODS tickets.
resource: /ansible/roles/services/kifshare
tags: [irods, tickets, public-links, downloads, jvm]
timestamp: 2026-07-20T00:00:00Z
---

kifshare serves the public "quick share" download pages for files shared out
of the data store: its config is built around [iRODS](/infrastructure/irods.md)
tickets, with download-instruction templates for curl, wget, iget, and DE
import that all interpolate a `ticket-id`. It connects to iRODS on port 1247
using `irods_user`/`irods_password` in the configured zone, and to
[RabbitMQ](/infrastructure/rabbitmq.md) via `kifshare.amqp.uri`. It is a JVM
service (`JAVA_TOOL_OPTIONS` from the `java-tool-options` configmap) listening
on port 60000, exposed in-cluster as Service `kifshare` on port 80; the common
role also reserves `kifshare_nodeport: 31340` for external access.

- **Source repo:** [cyverse-de/kifshare](https://github.com/cyverse-de/kifshare)
- **Image:** `harbor.cyverse.org/de/kifshare` (pinned in
  `files/kifshare.json`)

## Configuration

Unlike the job services, kifshare uses a properties-file template:
`templates/kifshare.properties.j2` is rendered into the `kifshare-configs`
secret and mounted at `/etc/iplant/de/kifshare.properties`. Notable group_vars
consumed: `irods_host`, `irods_user`, `irods_password`, `irods_zone`, and the
`de_amqp_*` connection settings. The template also fixes presentation details
(footer text, favicon, CSS/JS assets, client cache policy). Tracing exports to
[Jaeger](/infrastructure/jaeger.md) via OTEL variables from the `configs`
secret. Defaults: `kifshare_replicas: 2`.

## Deploying

```
ansible-playbook -i $INVENTORY deploy_it.yml --tags kifshare
```

See [Building and Deploying Services](/playbooks/build-and-deploy.md).

# Citations

1. `ansible/roles/services/kifshare/files/kifshare.json` — image and pinned tag/digest.
2. `ansible/roles/services/kifshare/templates/kifshare.properties.j2` — iRODS, AMQP, and ticket download-flag configuration.
3. `ansible/roles/services/kifshare/templates/k8s/kifshare.yml.j2` — Deployment/Service, JVM env, port 60000.
4. `ansible/roles/common/defaults/main.yml` — `kifshare_nodeport: 31340` and `source_repos` entry.
