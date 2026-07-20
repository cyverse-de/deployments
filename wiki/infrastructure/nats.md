---
type: Service
title: NATS
description: How NATS is installed via its Helm chart by the nats role, and how to download its TLS certs and creds from cluster secrets.
resource: /docs/nats.md
tags: [nats, messaging, tls, kubernetes.yml]
timestamp: 2026-07-20T00:00:00Z
---

NATS is installed via its Helm chart by the `nats` role, which runs in `kubernetes.yml` under the `nats` tag. To
install NATS within the cluster using default values, run the following, substituting the path to the KUBECONFIG file
as appropriate:

```bash
export KUBECONFIG=~/.kube/admin.conf

ansible-playbook -i /path/to/inventory --tags nats kubernetes.yml
```

## Downloading certs and creds

The best way to get an accurate version of the services.creds and TLS files is to grab them directly from the secrets and ConfigMaps used by the services. The `nats-box` pod does not keep those files around across restarts, so you may get invalid files or be fooled into thinking that the cluster hasn't been initialized if that pod has restarted at some point.

In most cases, the client and server certificate authorities will be the same, but we're showing how to download them both for completeness.

These certificates are cert-manager-managed and self-signed; if they expire, see [Certificate Management](/playbooks/certificate-management.md) for renewal and the list of NATS-connected services to restart.

Make sure that your KUBECONFIG environment variable is set to the correct kubeconfig file. Replace the namespace as needed in each case.

Make sure you have the following tools installed:

- `kubectl`
- `jq`
- `base64`

### NATS client TLS files

On Linux:

```bash
kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["ca.crt"]' | base64 -d > nats-client-ca.crt

kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["tls.crt"]' | base64 -d > nats-tls-client.crt

kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["tls.key"]' | base64 -d > nats-tls-client.key
```

On MacOS:

```bash
kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["ca.crt"]' | base64 -D > nats-client-ca.crt

kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["tls.crt"]' | base64 -D > nats-tls-client.crt

kubectl -n qa get secrets nats-client-tls -o json | jq -r '.data["tls.key"]' | base64 -D > nats-tls-client.key
```

### NATS server TLS files

On Linux:

```bash
kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["ca.crt"]' | base64 -d > nats-server-ca.crt

kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["tls.crt"]' | base64 -d > nats-tls-server.crt

kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["tls.key"]' | base64 -d > nats-tls-server.key
```

On MacOS:

```bash
kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["ca.crt"]' | base64 -D > nats-server-ca.crt

kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["tls.crt"]' | base64 -D > nats-tls-server.crt

kubectl -n qa get secrets nats-server-tls -o json | jq -r '.data["tls.key"]' | base64 -D > nats-tls-server.key
```

# Citations

[1] `docs/nats.md` — source document for this page.
[2] `ansible/roles/nats/` — role that installs NATS via its Helm chart.
