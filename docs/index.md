# DE Operations Documentation

This directory contains operational runbooks and troubleshooting guides for the CyVerse
Discovery Environment platform. For Ansible deployment procedures (playbooks, tags,
inventory setup), see [ansible/docs/index.md](../ansible/docs/index.md).

---

## Operations runbooks

| Runbook | Covers |
|---|---|
| [ops-runbook.md](ops-runbook.md) | Health checks, restarts, scaling, rollbacks, log access |
| [admin-procedures.md](admin-procedures.md) | Subscriptions, VICE access, workshop provisioning, DOI requests, alerts |
| [batch-analyses-troubleshooting.md](batch-analyses-troubleshooting.md) | Stuck/failed batch analyses, output missing, status pipeline |
| [vice-troubleshooting.md](vice-troubleshooting.md) | VICE interactive apps: loading page stuck, image pull failures, crashes |
| [certificate-management.md](certificate-management.md) | cert-manager, Let's Encrypt, HAProxy cert renewal |
| [keycloak.md](keycloak.md) | Client secret rotation, admin users, auth failure diagnosis |
| [postgresql.md](postgresql.md) | Migrations, backups, diagnostic queries |
| [irods.md](irods.md) | data-info connectivity, CSI driver, service account rotation, file transfers |
| [nats.md](nats.md) | NATS installation, cert/creds extraction |
| [rabbitmq.md](rabbitmq.md) | RabbitMQ installation and configuration |
| [haproxy.md](haproxy.md) | HAProxy deployment |
| [ldap.md](ldap.md) | OpenLDAP deployment |
