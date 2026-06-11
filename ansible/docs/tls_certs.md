# TLS Certificate Deployment playbooks

This playbook is for copying TLS certificates to hosts.

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
