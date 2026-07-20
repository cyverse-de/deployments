---
type: Service
title: RabbitMQ
description: How RabbitMQ is installed and configured for the DE services by the rabbitmq.yml and rabbitmq_configure.yml playbooks.
resource: /docs/rabbitmq.md
tags: [rabbitmq, amqp, messaging]
timestamp: 2026-07-20T00:00:00Z
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

# Citations

[1] `docs/rabbitmq.md` — source document for this page.
[2] `ansible/rabbitmq.yml`, `ansible/rabbitmq_configure.yml` — the playbooks described here.
