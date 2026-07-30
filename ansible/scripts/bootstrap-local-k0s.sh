#!/usr/bin/env bash
#
# Installs the single-node k0s cluster that local.yml deploys onto, and creates
# the pieces of host state Ansible cannot: the kubelet plugin directories for
# the iRODS CSI driver, and an admin kubeconfig owned by the invoking user.
#
# This is the whole of the cluster-side host preparation. The workstation's
# PostgreSQL is deliberately left alone; it is only involved at all under
# local_db_provider: host, and then it is not the deployment's to reconfigure.
#
# Run with sudo. Idempotent enough to re-run after a failed install; pass
# --reset to tear an existing cluster down first.

set -euo pipefail

# Where the OpenEBS hostpath provisioner keeps its volumes. Outside
# /var/lib/k0s, so k0s reset leaves it behind.
openebs_dir=/var/openebs/local

usage() {
    cat <<EOF
Usage: sudo $(basename "$0") [--reset]

Installs a single-node k0s controller, waits for its API server, creates the
iRODS CSI driver's kubelet directories, and writes an admin kubeconfig to
~/.kube/local-admin.conf for the user invoking sudo.

  --reset   Stop and reset any existing k0s installation first. This destroys
            the cluster, everything running on it, and the hostpath volumes
            under ${openebs_dir} — including the database, if it runs in the
            cluster. A reboot afterwards is recommended before reinstalling,
            to clear netfilter rules the CNI leaves behind.

            To keep the cluster and its ~11 GiB image cache, use
            local-teardown.yml instead.
  -h        Show this help
EOF
}

reset=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset) reset=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script needs root; re-run it with sudo." >&2
    exit 1
fi

target_user="${SUDO_USER:-root}"
target_home="$(getent passwd "${target_user}" | cut -d: -f6)"
if [[ -z "${target_home}" ]]; then
    echo "Could not determine the home directory of ${target_user}." >&2
    exit 1
fi
kubeconfig="${target_home}/.kube/local-admin.conf"

if [[ "${reset}" == true ]]; then
    echo "== stopping and resetting the existing k0s installation"
    k0s stop || true
    k0s reset || true

    # k0s reset does not know about this: the hostpath provisioner stores
    # volumes outside /var/lib/k0s, and destroying the cluster removes the
    # PersistentVolume objects without giving anything the chance to reclaim
    # the directories behind them. Left alone they accumulate one orphaned
    # tree per rebuild — a few megabytes for a config volume, gigabytes once
    # the database runs in the cluster.
    if [[ -d "${openebs_dir}" ]]; then
        echo "== removing orphaned hostpath volumes from ${openebs_dir}"
        du -sh "${openebs_dir}" 2>/dev/null || true
        rm -rf "${openebs_dir:?}"/*
    fi
    echo
    echo "Reset done. Reboot before reinstalling: k0s reset removes its own"
    echo "directories and interfaces but leaves netfilter rules behind, and a"
    echo "stale rule surfaces later as a deployment bug rather than a network"
    echo "one. Re-run this script without --reset afterwards."
    exit 0
fi

# --single gives a combined controller/worker with no taint, which is what a
# one-machine deployment wants. --enable-worker would add a master NoSchedule
# taint instead, and nothing would schedule until node-prep stripped it.
echo "== installing the k0s controller"
k0s install controller --single

echo "== starting k0s"
k0s start

echo "== waiting for the API server"
for _ in $(seq 1 120); do
    if k0s status 2>/dev/null | grep -q "Kube-api probing successful: true"; then
        break
    fi
    sleep 1
done
if ! k0s status 2>/dev/null | grep -q "Kube-api probing successful: true"; then
    echo "The API server did not come up; check 'k0s status' and the journal." >&2
    exit 1
fi

# Otherwise created by a kubernetes.yml play that needs root on every worker.
echo "== creating the iRODS CSI driver's kubelet directories"
mkdir -p /var/lib/k0s/kubelet/plugins/irods.csi.cyverse.org \
         /var/lib/k0s/kubelet/plugins_registry

echo "== writing ${kubeconfig}"
install -d -o "${target_user}" -g "${target_user}" "${target_home}/.kube"
# k0s writes whatever address the node had at install time and keeps it, so a
# DHCP lease or a VPN interface coming and going later breaks every kubectl
# call. On a single-node cluster the API server is always on loopback.
k0s kubeconfig admin | sed -E 's#(server: https://)[^:]+:#\1127.0.0.1:#' >"${kubeconfig}"
chown "${target_user}:${target_user}" "${kubeconfig}"
chmod 600 "${kubeconfig}"

echo
echo "== node"
k0s kubectl get nodes -o wide

# The inventory's k8s_pods_cidr and k8s_services_cidr have to match these:
# they become local-exim's relay allowlist, and a mismatch silently rejects
# outbound mail from every DE pod.
echo
echo "== CIDRs the inventory must agree with"
echo -n "  podCIDR:     "
k0s kubectl get node -o jsonpath='{.items[0].spec.podCIDR}{"\n"}'
echo -n "  serviceCIDR: "
k0s kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null |
    grep -o 'service-cluster-ip-range=[^"]*' | cut -d= -f2 ||
    echo "(check /etc/k0s/k0s.yaml; k0s defaults to 10.96.0.0/12)"

echo
echo "Done. Next: export KUBECONFIG=${kubeconfig} and run local.yml."
