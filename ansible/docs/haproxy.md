# HAProxy deployment playbooks

HAProxy is used in two places in a DE deployment, handled by separate roles:

- The `haproxy.yml` playbook installs HAProxy with a baseline configuration onto the hosts in the `de_proxy` group
  (via the `haproxy` role). It does not install the TLS certificates; for that, use the `tls_certs_main.yml` playbook
  (see [tls_certs.md](tls_certs.md)).
- The `ui_haproxy` role configures the proxy that fronts the DE UI and related services (Sonora, the user portal,
  Harbor, and GoCD, depending on which are enabled), forwarding traffic to NodePorts on the Kubernetes worker nodes.
  It runs in `kubernetes.yml` against the `de_haproxy` group under the `ui-haproxy` tag.

`kubernetes.yml` also sets up a separate HAProxy load balancer for the Kubernetes API server on the `k8s_api_proxy`
hosts (the `haproxy` and `k8s_haproxy` roles, under the `haproxy` tag).

## Inventory Setup

```
[de_proxy]
proxy-node.example.org

[de_haproxy]
proxy-node.example.org

[k8s_de_workers]
k8s-node-1.example.org
k8s-node-2.example.org
```

The proxy groups should contain the server set up as the proxy node. DNS for the environment's main access point
should point to this server. The `k8s_de_workers` group should contain the nodes the DE might be running on; the
`ui_haproxy` configuration enumerates these nodes as its proxy backends.

## Group Variable Setup

The `ui_haproxy` role needs `de_hostname`, the external DNS name that should forward to Sonora. When the corresponding
components are enabled, it also uses `portal_hostname`, `harbor_fqdn`, and `gocd_external_domain`.
