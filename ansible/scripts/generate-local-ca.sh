#!/usr/bin/env bash
#
# Generates the local root CA that cluster_issuers imports when
# cluster_issuer_default_type is "ca", for deployments whose hostnames Let's
# Encrypt cannot validate.
#
# The root must permit one intermediate. The selfsigned certificate chain is
# root -> per-endpoint CA (de-selfsigned-ca, kc-selfsigned-ca, ...) -> leaf, so
# a pathlen:0 root — which is what mkcert issues — produces certificates that
# every individual check calls valid while clients reject the chain with "path
# length constraint exceeded".
#
# Trusting the root is left to the caller because it is the only step needing
# root; the command is printed at the end.

set -euo pipefail

DEFAULT_DIR="${HOME}/.local/share/de-local-ca"
DEFAULT_ORG="CyVerse DE local development"
DEFAULT_DAYS=3650

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Generates a self-signed root CA suitable for cluster_issuer_default_type: ca.

Options:
  -d DIR    Where to write rootCA.pem and rootCA-key.pem
            (default: ${DEFAULT_DIR})
  -o ORG    Organization and common name to issue under
            (default: ${DEFAULT_ORG})
  -n DAYS   Validity in days (default: ${DEFAULT_DAYS})
  -f        Overwrite an existing CA in DIR
  -h        Show this help

Point the inventory at the result:

  cluster_issuer_default_type: ca
  cluster_issuer_ca_cert_file: DIR/rootCA.pem
  cluster_issuer_ca_key_file:  DIR/rootCA-key.pem
EOF
}

dir="${DEFAULT_DIR}"
org="${DEFAULT_ORG}"
days="${DEFAULT_DAYS}"
force=false

while getopts ":d:o:n:fh" opt; do
    case "${opt}" in
        d) dir="${OPTARG}" ;;
        o) org="${OPTARG}" ;;
        n) days="${OPTARG}" ;;
        f) force=true ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required but was not found on PATH" >&2
    exit 1
fi

cert="${dir}/rootCA.pem"
key="${dir}/rootCA-key.pem"

if [[ -e "${cert}" || -e "${key}" ]] && [[ "${force}" != true ]]; then
    echo "A CA already exists in ${dir}; pass -f to replace it." >&2
    echo "Replacing it invalidates every certificate already issued beneath it," >&2
    echo "so re-run the cert-issuers, traefik, ingress and keycloak tags after." >&2
    exit 1
fi

mkdir -p "${dir}"
config="$(mktemp)"
trap 'rm -f "${config}"' EXIT

cat >"${config}" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = ${org}
CN = ${org} CA
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:4096 -sha256 -days "${days}" -nodes \
    -keyout "${key}" -out "${cert}" -config "${config}"
chmod 600 "${key}"
chmod 644 "${cert}"

echo
echo "Wrote ${cert} and ${key}."
echo
echo "Trust it (needs root; covers the system store and the NSS store Firefox"
echo "and Chrome read through p11-kit):"
echo
echo "  sudo trust anchor --store ${cert}"
echo
echo "Then set in the inventory:"
echo
echo "  cluster_issuer_default_type: ca"
echo "  cluster_issuer_ca_cert_file: ${cert}"
echo "  cluster_issuer_ca_key_file: ${key}"
