#!/usr/bin/env bash
#
# Shared by bootstrap-local-k0s.sh and repair-local-k0s-api-address.sh: picking
# a stable address for the API server to advertise, and writing it into
# /etc/k0s/k0s.yaml.
#
# Why this exists at all. With no config file, k0s auto-detects
# spec.api.address at every start from the default route's source address, and
# bakes it into the component kubeconfigs and the `kubernetes` Service
# endpoint. On a workstation that address is a DHCP lease. When the lease
# moves, kube-proxy and CoreDNS lose the API server and the cluster fails in a
# way that reads as healthy: everything programmed before the move keeps
# working, and only things created afterwards are silently never programmed.

# Overridable so the diagnostic can be exercised against a fixture without root.
k0s_config="${K0S_CONFIG:-/etc/k0s/k0s.yaml}"

# Sets two globals rather than echoing: k0s_api_address, and
# k0s_api_address_source describing where it came from so callers can warn when
# the choice is not a stable one. Globals because a command substitution would
# run this in a subshell and lose the second value.
k0s_api_address=
k0s_api_address_source=

detect_stable_api_address() {
    if [[ -n "${K0S_API_ADDRESS:-}" ]]; then
        k0s_api_address_source="K0S_API_ADDRESS override"
        k0s_api_address="${K0S_API_ADDRESS}"
        return 0
    fi

    # Tailscale hands out addresses from the CGNAT range 100.64.0.0/10 and
    # keeps them across reboots and network changes, which is exactly the
    # property the API address needs and the LAN lease lacks.
    local tailscale
    tailscale="$(ip -4 -o addr show 2>/dev/null |
        awk '{print $4}' | cut -d/ -f1 |
        awk -F. '$1 == 100 && $2 >= 64 && $2 <= 127' |
        head -1)"
    if [[ -n "${tailscale}" ]]; then
        k0s_api_address_source="Tailscale address"
        k0s_api_address="${tailscale}"
        return 0
    fi

    # Nothing stable to point at. Still better than leaving it unpinned --
    # pinned-but-wrong is one edit away from correct, whereas unpinned silently
    # re-breaks on every restart -- but say so.
    k0s_api_address_source="default route source address (NOT stable)"
    k0s_api_address="$(ip route get 1.1.1.1 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
}

# Writes a complete k0s.yaml. Only for a cluster that does not exist yet: it
# states the network block, and imposing those values on a running cluster
# would renumber it. Repairing an existing config edits the address in place
# instead.
write_k0s_config() {
    local address="$1" pod_cidr="${2:-10.244.0.0/16}" service_cidr="${3:-10.96.0.0/12}"

    mkdir -p "$(dirname "${k0s_config}")"
    cat >"${k0s_config}" <<EOF
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    # Pinned deliberately. Left unset, k0s re-detects this at every start from
    # the default route and bakes a DHCP lease into the component kubeconfigs
    # and the "kubernetes" Service endpoint; when the lease moves, kube-proxy
    # and CoreDNS lose the API server while everything already programmed keeps
    # working, so the cluster looks healthy and silently stops applying changes.
    #
    # Repair with scripts/repair-local-k0s-api-address.sh if this address ever
    # stops being reachable.
    address: ${address}
    sans:
      - ${address}
      - 127.0.0.1
      - localhost
      - $(hostname -s)

  # The k0s defaults, stated explicitly so that a future k0s release changing a
  # default cannot renumber a running cluster.
  network:
    podCIDR: ${pod_cidr}
    serviceCIDR: ${service_cidr}
    clusterDomain: cluster.local
    provider: kuberouter
EOF
}

# The address currently configured, or the empty string if there is no config
# file (in which case k0s is auto-detecting and nothing is pinned).
configured_api_address() {
    [[ -f "${k0s_config}" ]] || return 0
    awk '
        /^[[:space:]]*api:[[:space:]]*$/ { in_api = 1; next }
        in_api && /^[[:space:]]*address:[[:space:]]*/ {
            sub(/^[[:space:]]*address:[[:space:]]*/, "")
            print
            exit
        }
        in_api && /^[[:space:]]{0,2}[a-z]+:[[:space:]]*$/ { in_api = 0 }
    ' "${k0s_config}"
}

# True when a TCP connection to the API port succeeds.
api_address_reachable() {
    timeout 4 bash -c "cat < /dev/null > /dev/tcp/$1/6443" 2>/dev/null
}
