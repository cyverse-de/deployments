#!/usr/bin/env bash
#
# Diagnoses -- and with --fix, repairs -- a local k0s cluster whose API server
# is advertising an address that no longer reaches it.
#
# The symptom is not an outage. kube-proxy and CoreDNS lose their watches, so
# everything already programmed keeps working while anything created or changed
# afterwards is silently never programmed. A Service created since the drift
# does not resolve; a Deployment redeployed since it does not route. Both look
# like application bugs.
#
# Reading the cluster needs only a kubeconfig. Repairing it needs root, because
# it rewrites /etc/k0s/k0s.yaml and restarts k0scontroller.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/k0s-api-address.sh"

kubeconfig="${KUBECONFIG:-${HOME}/.kube/local-admin.conf}"
fix=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--fix]

Reports whether this k0s cluster's advertised API address still reaches it, and
what that has broken. A bare run only reads; it is safe to run any time.

  --fix     Repair: rewrite the address in /etc/k0s/k0s.yaml, restart
            k0scontroller, and verify. Needs root. The API server is briefly
            unavailable, so in-flight kubectl calls and deploys will error.
  -h        Show this help

Environment:
  KUBECONFIG       Defaults to ~/.kube/local-admin.conf, NOT ~/.kube/config --
                   this script is only ever meant for the local cluster, and
                   the default kubeconfig on this workstation points at QA.
  K0S_API_ADDRESS  The address to repair to. Defaults to 10.255.255.1, carried
                   on a dummy interface; it should match whatever
                   bootstrap-local-k0s.sh used.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix) fix=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

kubectl() { command kubectl --kubeconfig "${kubeconfig}" "$@"; }

# Guard against pointing this at a remote cluster. Repairing acts on this
# host's k0s, so operating on a cluster that is not this host's would report
# findings from one machine and fix another.
assert_local_cluster() {
    local server
    server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    case "${server}" in
        *127.0.0.1*|*localhost*) return 0 ;;
        "")
            echo "Could not read the cluster from ${kubeconfig}." >&2
            exit 2
            ;;
        *)
            echo "${kubeconfig} points at ${server}, which is not this host's" >&2
            echo "k0s cluster. Refusing: this script repairs local k0s only." >&2
            echo "Set KUBECONFIG=~/.kube/local-admin.conf." >&2
            exit 2
            ;;
    esac
}

api_error_count() {
    kubectl logs -n kube-system "$1" --since=5m 2>/dev/null |
        grep -c 'no route to host\|connection refused\|i/o timeout' || true
}

# kube-proxy and CoreDNS log a handful of these for a minute or two after a node
# boot or a k0scontroller restart, while the API server is still coming up. A
# component that has genuinely lost the API server keeps logging them, so a
# threshold tells a healthy cluster inspected right after boot apart from a
# broken one -- without it, --fix restarts k0scontroller over startup noise.
api_error_threshold=5

assert_local_cluster

configured="$(configured_api_address)"
endpoint="$(kubectl get endpoints kubernetes -n default \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
detected="${k0s_api_address}"

if [[ -n "${configured}" ]]; then
    api_address_reachable "${configured}" && configured_state=reachable || configured_state=UNREACHABLE
else
    configured_state="not pinned -- k0s re-detects at every start"
fi

api_address_interface_up && iface_state="up" || iface_state="ABSENT"
proxy_errors="$(api_error_count ds/kube-proxy)"
dns_errors="$(api_error_count deploy/coredns)"

printf '  %-22s %s\n' "config file:" "${k0s_config}$([[ -f ${k0s_config} ]] || echo ' (absent)')"
printf '  %-22s %s\n' "configured address:" "${configured:-<none>} (${configured_state})"
printf '  %-22s %s\n' "kubernetes endpoint:" "${endpoint:-<unknown>}"
printf '  %-22s %s\n' "standard address:" "${detected} on ${k0s_api_interface} (${iface_state})"
printf '  %-22s %s\n' "kube-proxy errors/5m:" "${proxy_errors} (threshold ${api_error_threshold})"
printf '  %-22s %s\n' "coredns errors/5m:" "${dns_errors} (threshold ${api_error_threshold})"
echo

# Written as an if rather than a run of `test && drifted=true`, where whether
# set -e fires depends on a line's position in the list.
#
# Broken and non-standard are kept apart on purpose. A cluster pinned to a
# reachable address that is not the dummy one works fine; it is only carrying
# an address that could move later. Reporting that as a fault would cry wolf on
# a healthy cluster, so it is advice, and only a real fault sets the exit code.
drifted=false
if [[ "${configured_state}" == UNREACHABLE ]] ||
   [[ -z "${configured}" ]] ||
   { [[ -n "${endpoint}" ]] && ! api_address_reachable "${endpoint}"; } ||
   (( proxy_errors >= api_error_threshold )) ||
   (( dns_errors >= api_error_threshold )); then
    drifted=true
fi

nonstandard=false
if [[ "${drifted}" == false && "${configured}" != "${detected}" ]]; then
    nonstandard=true
fi

if [[ "${drifted}" == false ]]; then
    echo "No drift. The advertised address reaches the API server and neither"
    echo "kube-proxy nor CoreDNS is reporting errors."
    if [[ "${nonstandard}" == false ]]; then
        exit 0
    fi
    echo
    echo "It is pinned to ${configured}, though, not the dummy address"
    echo "${detected}. That works until ${configured} moves or the interface"
    echo "carrying it goes away."
    if [[ "${fix}" == false ]]; then
        echo "Migrate with --fix when convenient; it restarts k0scontroller."
        exit 0
    fi
    echo "Migrating, since --fix was given."
    echo
fi

# Guarded: a migration from a healthy non-standard address reaches here too,
# and announcing a fault it has already ruled out would contradict itself.
if [[ "${drifted}" == true ]]; then
    echo "DRIFT DETECTED."
    if [[ -z "${configured}" ]]; then
        echo "  The address is not pinned, so k0s re-detects it at every start and"
        echo "  will drift again on the next lease change."
    fi
    if (( dns_errors >= api_error_threshold )); then
        echo "  CoreDNS cannot reach the API server, so any Service created since"
        echo "  the drift does not resolve."
    fi
    if (( proxy_errors >= api_error_threshold )); then
        echo "  kube-proxy cannot reach the API server, so any endpoint changed"
        echo "  since the drift is not programmed and those Services do not route."
    fi
    echo

    if [[ "${fix}" == false ]]; then
        echo "Re-run with --fix (as root) to repair."
        exit 1
    fi
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "--fix needs root; re-run it with sudo." >&2
    exit 1
fi

# Before the config, so the controller never starts pointing at an address that
# is not there yet.
echo "== ensuring ${k0s_api_interface} (${detected}) via ${k0s_api_unit}"
ensure_api_address_interface
if ! api_address_interface_up; then
    echo "${detected} did not come up on ${k0s_api_interface}." >&2
    echo "Check 'systemctl status ${k0s_api_unit}'." >&2
    exit 1
fi

echo "== repairing to ${detected}"
if [[ -f "${k0s_config}" ]]; then
    # Edit in place rather than regenerating: an existing cluster's network
    # block is load-bearing, and rewriting it from defaults could renumber a
    # cluster whose CIDRs were customised.
    cp -a "${k0s_config}" "${k0s_config}.bak.$(date +%Y%m%d%H%M%S)"
    if [[ -n "${configured}" ]]; then
        # sans carries the same address, and k0s puts it in the apiserver
        # certificate; leaving the old one there makes the file disagree with
        # itself and can leave the new address off the cert.
        sed -i -E \
            -e "s|^([[:space:]]*address:[[:space:]]*)${configured}[[:space:]]*$|\\1${detected}|" \
            -e "s|^([[:space:]]*-[[:space:]]*)${configured}[[:space:]]*$|\\1${detected}|" \
            "${k0s_config}"
        if [[ "$(configured_api_address)" != "${detected}" ]]; then
            echo "  could not rewrite spec.api.address in ${k0s_config}; fix it by hand." >&2
            exit 1
        fi
    else
        echo "  ${k0s_config} exists but has no spec.api.address; add it by hand." >&2
        exit 1
    fi
    echo "   updated in place (backup alongside it)"
else
    # No config at all: the CIDRs the cluster is actually running on have to be
    # carried over, or the generated file would impose the defaults on it.
    pod_cidr="$(kubectl get cm -n kube-system kube-proxy \
        -o jsonpath='{.data.config\.conf}' 2>/dev/null |
        awk '/clusterCIDR:/ {print $2; exit}')"
    service_cidr="$(kubectl get ds -n kube-system kube-router \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null |
        grep -o 'service-cluster-ip-range=[^"]*' | cut -d= -f2)"
    echo "   creating it, preserving podCIDR=${pod_cidr:-default} serviceCIDR=${service_cidr:-default}"
    write_k0s_config "${detected}" "${pod_cidr:-10.244.0.0/16}" "${service_cidr:-10.96.0.0/12}"
fi

echo "== restarting k0scontroller"
systemctl restart k0scontroller.service

echo "== waiting for the API server"
for _ in $(seq 1 120); do
    api_address_reachable 127.0.0.1 && break
    sleep 1
done

# The API server rewrites this endpoint from its own advertised address, so it
# is the authoritative confirmation that the new address took effect.
echo "== verifying"
for _ in $(seq 1 30); do
    endpoint="$(kubectl get endpoints kubernetes -n default \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    [[ "${endpoint}" == "${detected}" ]] && break
    sleep 2
done

printf '  %-22s %s\n' "kubernetes endpoint:" "${endpoint:-<unknown>}"
if [[ "${endpoint}" != "${detected}" ]]; then
    echo "The endpoint did not move to ${detected}; check 'journalctl -u k0scontroller'." >&2
    exit 1
fi

# Errors are counted over a window that still includes the broken period, so a
# non-zero count here is expected; what matters is that they stopped.
echo "   waiting 30s for kube-proxy and CoreDNS to reconnect"
sleep 30
printf '  %-22s %s\n' "kube-proxy errors/1m:" \
    "$(kubectl logs -n kube-system ds/kube-proxy --since=1m 2>/dev/null | grep -c 'no route to host' || true)"
printf '  %-22s %s\n' "coredns errors/1m:" \
    "$(kubectl logs -n kube-system deploy/coredns --since=1m 2>/dev/null | grep -c 'no route to host' || true)"
echo
echo "Repaired. Any Service created while the cluster was drifted is only"
echo "now becoming resolvable; re-run the affected deploys if in doubt."
