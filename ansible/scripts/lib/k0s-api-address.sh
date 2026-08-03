#!/usr/bin/env bash
#
# Shared by bootstrap-local-k0s.sh and repair-local-k0s-api-address.sh: the
# stable address the API server advertises, the dummy interface that carries
# it, and writing it into /etc/k0s/k0s.yaml.
#
# Why this exists at all. With no config file, k0s auto-detects
# spec.api.address at every start from the default route's source address, and
# bakes it into the component kubeconfigs and the `kubernetes` Service
# endpoint. On a workstation that address is a DHCP lease. When the lease
# moves, kube-proxy and CoreDNS lose the API server and the cluster fails in a
# way that reads as healthy: everything programmed before the move keeps
# working, and only things created afterwards are silently never programmed.
#
# The fix is to advertise an address that belongs to no physical network: a
# dummy interface, brought up before k0s starts. It cannot drift because
# nothing outside this host assigns it, and it is the same on every
# workstation, so runbooks can name it.
#
# Deliberately not the node's LAN or VPN address. A LAN lease moves; a VPN
# address only exists on machines running that VPN, which is not something a
# team can be assumed to share. Deliberately not the kube-bridge address
# (10.244.0.1) either, tempting though it is: that interface is created by the
# CNI, which cannot start until the node has registered with the API server, so
# advertising it would deadlock a fresh install.

# Overridable so the diagnostic can be exercised against a fixture without root.
k0s_config="${K0S_CONFIG:-/etc/k0s/k0s.yaml}"

k0s_api_interface=k0s-api
k0s_api_unit=k0s-api-address.service
# Outside both the pod CIDR (10.244.0.0/16) and the service CIDR
# (10.96.0.0/12), and unusual enough not to collide with a home or campus LAN.
k0s_api_address_default=10.255.255.1

# The address this host should advertise. Fixed unless overridden -- there is
# nothing to detect, which is the point.
k0s_api_address="${K0S_API_ADDRESS:-${k0s_api_address_default}}"

# Creates and enables the unit that carries the address, then starts it. Safe
# to re-run: the unit ignores failures from the two `add` commands so that a
# restart does not fail on an interface that already exists.
ensure_api_address_interface() {
    local ip_bin
    ip_bin="$(command -v ip)"

    cat >"/etc/systemd/system/${k0s_api_unit}" <<EOF
[Unit]
Description=Stable address for the k0s API server to advertise
Documentation=file://$(dirname "${BASH_SOURCE[0]}")/k0s-api-address.sh
# k0s bakes this address into the component kubeconfigs, so it has to exist
# before the controller starts or they come up pointing at nothing.
Before=k0scontroller.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
# The leading '-' makes these non-fatal: on a restart the link and address are
# already there, and that is success, not failure.
ExecStart=-${ip_bin} link add ${k0s_api_interface} type dummy
ExecStart=-${ip_bin} addr add ${k0s_api_address}/32 dev ${k0s_api_interface}
ExecStart=${ip_bin} link set ${k0s_api_interface} up
ExecStop=-${ip_bin} link del ${k0s_api_interface}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${k0s_api_unit}" >/dev/null
}

# True when the address is actually present on this host.
api_address_interface_up() {
    ip -4 -o addr show dev "${k0s_api_interface}" 2>/dev/null |
        grep -q "inet ${k0s_api_address}/"
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
    # A dummy interface (${k0s_api_interface}), brought up by
    # ${k0s_api_unit} before the controller starts.
    #
    # Left unset, k0s re-detects this at every start from the default route and
    # bakes a DHCP lease into the component kubeconfigs and the "kubernetes"
    # Service endpoint; when the lease moves, kube-proxy and CoreDNS lose the
    # API server while everything already programmed keeps working, so the
    # cluster looks healthy and silently stops applying changes. An address
    # that belongs to no physical network cannot move.
    #
    # Diagnose with scripts/repair-local-k0s-api-address.sh.
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
