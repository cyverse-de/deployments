---
type: Service
title: RabbitMQ
description: How RabbitMQ is installed and configured for the DE services, either on a host by rabbitmq.yml and rabbitmq_configure.yml or in-cluster by the rabbitmq_k8s role.
resource: /docs/rabbitmq.md
tags: [rabbitmq, amqp, messaging]
timestamp: 2026-07-30T00:00:00Z
---

These playbooks can be used to install and/or configure RabbitMQ for usage by the DE services.

## Playbooks

### rabbitmq.yml

This playbook both installs and configures RabbitMQ.

### rabbitmq_configure.yml

This playbook only configures RabbitMQ, and is intended for use when RabbitMQ is installed separately, for example when iRODS and the DE share a broker.

## Inventory Setup

```
[amqp-brokers]
rabbitmq-host.example.org
```

The `amqp-brokers` group should include the host to install and/or configure RabbitMQ on.

## Group Variable Setup

Both playbooks depend on the `amqp.admin_user` and `amqp.admin_password` variables. The configuration tasks additionally depend on `amqp.de` and `amqp.irods`, which are definitions of vhosts.

## In-cluster RabbitMQ

Both playbooks act on a host: they install packages and drive `rabbitmqctl`
over SSH under `become`, so neither can target a broker running as a pod. The
`rabbitmq_k8s` role is the alternative for deployments with no broker host —
it deploys a single-replica broker with the management plugin and provisions
the same vhosts and users through `kubectl exec`. `rabbitmq_k8s_vhosts`
defaults to the `de_amqp_*` and `irods_amqp_*` pairs, so the variables the DE's
config templates read do not change; only `de_amqp_host` / `irods_amqp_host`
move to the in-cluster Service. The role is not in `kubernetes.yml`; it runs
from `local.yml` (see
[Local Single-Node Deployment](/playbooks/local-single-node-deployment.md)).

Pointing `irods_amqp_host` at a broker that no iRODS instance publishes to is a
supported configuration but has a consequence worth stating: `dewey`,
`info-typer`, and `infosquito2` will run and idle, and nothing will populate
the [OpenSearch](/infrastructure/opensearch.md) index.

### Why it is pinned to RabbitMQ 3

`rabbitmq_k8s_version` stays on 3.x. RabbitMQ 4 raised the minimum negotiated
`frame_max` to 8192, and sonora's AMQP client proposes 4096, so the broker
closes every connection it opens during negotiation. Only the broker names the
reason:

```
failed to negotiate connection parameters: negotiated frame_max = 4096
is lower than the minimum allowed value (8192)
```

The client side reports `AMQP error: read ECONNRESET` and reconnects forever,
so the cause is invisible from the failing service. Moving to 4.x needs that
client raising its frame size first.

### Why the pod has a fixed hostname

RabbitMQ takes its node name from the hostname and stores its Mnesia database
in a directory named after it, so the pod template sets `spec.hostname` rather
than letting it default to the pod name. Without that, a broker keeps no state
across a reschedule: it comes up on a new node name, finds no database, and
creates an empty one — leaving the previous directory orphaned on the volume.
The vhosts, users, and permissions this role provisions are gone, and the
symptom is every AMQP client failing with `(403) username or password not
allowed`, which points at credentials rather than at a broker that lost them.

A single-replica broker on one volume is the only arrangement this role
supports, so the fixed hostname costs nothing. Anything multi-node would want a
StatefulSet for the same reason.

# Citations

[1] `docs/rabbitmq.md` — source document for this page.
[2] `ansible/rabbitmq.yml`, `ansible/rabbitmq_configure.yml` — the playbooks described here.
[3] `ansible/roles/rabbitmq_k8s/` — the in-cluster alternative.
