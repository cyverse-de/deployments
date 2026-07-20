---
type: Runbook
title: Deploying TLS Certificates
description: How the tls_certs_main.yml playbook copies the combined TLS certificate to the proxy nodes for HAProxy.
resource: /docs/certificate-management.md
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

## Renewing the combined certificate

The combined certificate is issued by an external CA and managed outside Kubernetes; it does
not renew automatically. Check its expiry on the proxy host with
`openssl x509 -enddate -noout -in /etc/ssl/cyverse.combined`. To renew, obtain the new
PEM-formatted cert chain and private key, concatenate them
(`cat fullchain.pem privkey.pem > cyverse.combined`), run the playbook as above, then reload
HAProxy:

```
ansible de_proxy -i /path/to/inventory -K --become -m service -a "name=haproxy state=reloaded"
```

For the cert-manager-managed certificates used elsewhere in the DE, see
[Certificate Management](/playbooks/certificate-management.md).

# Citations

[1] `docs/certificate-management.md` — source document; §5 covers the HAProxy combined certificate and this playbook.
[2] `ansible/tls_certs_main.yml` — the playbook described here.
