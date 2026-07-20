---
type: Runbook
title: Deploying TLS Certificates
description: How the tls_certs_main.yml playbook copies the combined TLS certificate to the proxy nodes for HAProxy.
resource: /ansible/docs/tls_certs.md
tags: [tls, certificates, haproxy]
timestamp: 2026-07-20T00:00:00Z
---

This playbook is for copying TLS certificates to hosts. The certificates are used by
[HAProxy](/infrastructure/haproxy.md) on the proxy nodes.

## Playbooks

### tls_certs_main.yml

Copies the combined TLS cert to the proxy nodes.

## Inventory Setup

```
[de_proxy]
proxy-node.example.org
```

These inventories should match other playbooks used for deployment.

## Variable setup

This playbook needs one variable: `combined_cert_src`, the local path of the `cyverse.combined` certificate to be used
by HAProxy. It defaults to `/etc/ssl/cyverse.combined` and most likely should be passed on the command line rather
than set in group vars.

## Example

```
ansible-playbook -i /home/user/inventory-repo/inventory/ -e combined_cert_src=/home/user/certificates-source/ssl/cyverse.combined -K tls_certs_main.yml
```

# Citations

[1] `ansible/docs/tls_certs.md` — source document for this page.
[2] `ansible/tls_certs_main.yml` — the playbook described here.
