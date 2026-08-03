---
name: repairing-the-local-cluster-api-address
description: Use when the local single-node k0s cluster behaves as though only *new* things are broken — a Service that will not resolve, a just-redeployed pod that will not route, "no route to host" between cluster components — or before blaming a deploy that used to work. Diagnoses and repairs a stale advertised API address.
---

# Repairing the Local Cluster's API Address

## Overview

The local k0s cluster advertises one address for its API server. Every
in-cluster component reaches the API through it, directly or via the
`kubernetes` Service. On a workstation that address is a DHCP lease, and when
the lease moves the cluster does not go down — it goes **half-down**, which is
much harder to recognise.

kube-proxy and CoreDNS lose their watches and keep serving what they had
already programmed. So:

- Services that existed before the move keep resolving and routing.
- Services created *after* the move do not resolve at all.
- Pods redeployed *after* the move get a new IP that is never programmed, so
  their Service stops routing while the pod is healthy.

Nothing reports an outage. The failures surface as an application bug in
whatever you happened to be working on.

## When to Use

- A Service you just created does not resolve (`bad address`), but older ones do.
- A service you just redeployed is `Running` and healthy but unreachable
  through its ClusterIP, while its pod IP works directly.
- `no route to host` in kube-proxy, CoreDNS, or a job talking to another service.
- After the workstation changes networks, reboots onto a new lease, or a VPN
  interface appears or disappears.
- NOT for a service that has never worked — that is a deploy problem. This is
  specifically about things breaking *after* they worked, or only-new-things
  breaking.

## Diagnosis

Run the diagnostic. It only reads, so it is safe at any time:

```bash
cd ansible/scripts
KUBECONFIG=~/.kube/local-admin.conf ./repair-local-k0s-api-address.sh
```

It reports the configured address and whether it is reachable, the `kubernetes`
Service endpoint, the best address available now, and how many API errors
kube-proxy and CoreDNS logged in the last five minutes. Exit `0` means no
drift; `1` means drift; `2` means it refused (see the pitfalls below).

Doing it by hand, the two facts that matter:

```bash
kubectl get endpoints kubernetes -n default          # what the API advertises
kubectl logs -n kube-system deploy/coredns --since=2m | grep -c 'no route to host'
```

Then check whether that endpoint address is actually this host:

```bash
ip -4 addr show | grep inet
```

## Repair

```bash
cd ansible/scripts
sudo KUBECONFIG=~/.kube/local-admin.conf ./repair-local-k0s-api-address.sh --fix
```

It rewrites `spec.api.address` in `/etc/k0s/k0s.yaml` (backing the file up
first), restarts `k0scontroller`, waits for the API server, and verifies both
that the `kubernetes` endpoint moved and that the component errors stopped.

The API server is briefly unavailable during the restart, so in-flight
`kubectl` calls and any running deploy will error. Nothing in the `de`
namespace restarts as a result.

Afterwards, re-run the deploys for anything created or changed while the
cluster was drifted — those objects were never programmed, and the repair does
not retroactively apply them.

## Pitfalls

- **Check which cluster you are on first.** `~/.kube/config` on this
  workstation points at **QA**, and both contexts are named `k0s-cluster`, so
  `kubectl config current-context` cannot tell them apart. The script defaults
  to `~/.kube/local-admin.conf` and exits `2` rather than act on a cluster
  whose server is not loopback — but a bare `kubectl` will happily answer from
  QA and make the local cluster look fine.
- **`--tail` lies about time.** `kubectl logs --tail=5` returns the last five
  lines however old they are, so a repaired cluster still shows the errors from
  before the repair. Use `--since=2m` to ask whether it is *currently* broken.
- **Restarting k0s without pinning the address fixes nothing.** With no config
  file k0s re-detects the address at every start and picks the current DHCP
  lease, which is both unstable and possibly absent from the API server's
  certificate SANs. Pin it.
- **Do not regenerate `/etc/k0s/k0s.yaml` for a running cluster.** Its network
  block is load-bearing; writing defaults over customised CIDRs renumbers the
  cluster. The script edits the address in place when the file exists, and only
  generates a whole file when there is none — and then carries the live CIDRs
  over.
- **A pod cannot reach the host's `127.0.0.1`.** The advertised address has to
  be a routable node address, so loopback is not an option even though the
  admin kubeconfig uses it.

## Prevention

`bootstrap-local-k0s.sh` now writes `/etc/k0s/k0s.yaml` before installing, with
the address pinned to this host's Tailscale address when it has one — stable
across reboots and lease changes, unlike the LAN address. Set `K0S_API_ADDRESS`
to override. A host with no Tailscale address gets the default route's source
address and a warning that it will drift again.

This is the server-side half of a problem the script already handled for
clients: it rewrites the admin kubeconfig to `127.0.0.1` for the same reason.
