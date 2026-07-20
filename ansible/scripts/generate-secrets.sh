#!/usr/bin/env bash
#
# Generates the secret files that the secret_loader role expects to find in a
# deployment inventory repo, under <inventory repo>/secrets/:
#
#   secrets/secring.gpg               -> gpg-keys secret (apps OAuth token encryption)
#   secrets/signing_key/private-key.pem  -> signing-keys secret (terrain JWT signing)
#   secrets/signing_key/public-key.pem   -> signing-keys secret
#   secrets/accepted_keys/terrain.pem    -> accepted-keys secret (terrain JWT validation)
#
# The target inventory directory is given as an argument; the secrets are
# written next to it, matching how secret_loader resolves its secrets_dir
# (dirname of the inventory directory + "secrets").
#
# The GPG keyring is exported ASCII-armored because the Ansible file lookup is
# text-based and would corrupt a binary keyring; apps reads it through
# BouncyCastle, which auto-detects armored input.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] INVENTORY_DIR

Generates the secret files needed by the DE Ansible automation for the
deployment inventory repo containing INVENTORY_DIR. INVENTORY_DIR is the
inventory directory itself (the one you pass to ansible-playbook -i) and
must contain group_vars/all.yaml. Files are written to
<dirname of INVENTORY_DIR>/secrets, where the secret_loader role looks for
them:

  secrets/secring.gpg                (gpg-keys secret; used by the apps
                                      service to encrypt OAuth tokens)
  secrets/signing_key/private-key.pem (signing-keys secret; terrain JWT)
  secrets/signing_key/public-key.pem  (signing-keys secret; terrain JWT)
  secrets/accepted_keys/terrain.pem   (accepted-keys secret; public keys of
                                       JWT issuers terrain will trust)

Passphrases are taken from environment variables when set, otherwise from
INVENTORY_DIR/group_vars/all.yaml:

  PGP_KEY_PASSWORD         / pgp_key_password         (GPG keyring)
  JWT_SIGNING_KEY_PASSWORD / jwt_signing_key_password (JWT private key)

Both must match what the services are deployed with: apps reads the keyring
password from apps.pgp.key-password and terrain reads the JWT key password
from terrain.jwt.signing-key.password.

Options:
  --force            Overwrite existing output files.
  --secrets-dir DIR  Output directory (default: <dirname of INVENTORY_DIR>/secrets).
  --gpg-name NAME    Real name for the GPG key (default: "CyVerse Core Software").
  --gpg-email EMAIL  Email for the GPG key (default: "core-sw@cyverse.org").
  -h, --help         Show this help and exit.

Required tools:
  gpg     >= 2.1   (batch key generation with loopback pinentry and
                    explicit secret-key export)
  openssl >= 1.1.1 (or LibreSSL >= 3.0)

After a successful run, the script prints the secrets_loader_* variables to
set in INVENTORY_DIR/group_vars/all.yaml.
EOF
}

err() { echo "ERROR: $*" >&2; }
info() { echo "==> $*"; }

inventory_dir=""
secrets_dir=""
gpg_name="CyVerse Core Software"
gpg_email="core-sw@cyverse.org"
force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) force=true; shift ;;
        --secrets-dir) secrets_dir="${2:?--secrets-dir requires a directory argument}"; shift 2 ;;
        --gpg-name) gpg_name="${2:?--gpg-name requires an argument}"; shift 2 ;;
        --gpg-email) gpg_email="${2:?--gpg-email requires an argument}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) err "unknown option: $1 (see --help)"; exit 2 ;;
        *)
            if [[ -n "$inventory_dir" ]]; then
                err "unexpected extra argument: $1 (see --help)"
                exit 2
            fi
            inventory_dir="$1"; shift
            ;;
    esac
done

if [[ -z "$inventory_dir" ]]; then
    err "missing required INVENTORY_DIR argument (see --help)."
    exit 2
fi
if [[ ! -d "$inventory_dir" ]]; then
    err "inventory directory '${inventory_dir}' does not exist."
    exit 1
fi
inventory_dir="$(cd "$inventory_dir" && pwd)"
inventory_file="${inventory_dir}/group_vars/all.yaml"
if [[ ! -f "$inventory_file" ]]; then
    err "'${inventory_dir}' does not look like a deployment inventory directory:" \
        "expected ${inventory_file} to exist."
    exit 1
fi
[[ -n "$secrets_dir" ]] || secrets_dir="$(dirname "$inventory_dir")/secrets"

# version_ge A B: true when dotted version A >= B.
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

check_tools() {
    local failures=0

    if ! command -v gpg >/dev/null 2>&1; then
        err "gpg not found on PATH. Install GnuPG >= 2.1 (package 'gnupg2' on most distros)."
        failures=$((failures + 1))
    else
        local gpg_version
        gpg_version="$(gpg --version | head -1 | awk '{print $NF}')"
        if ! version_ge "$gpg_version" "2.1"; then
            err "gpg ${gpg_version} is too old; >= 2.1 is required for batch key" \
                "generation with loopback pinentry and secret-key export."
            failures=$((failures + 1))
        fi
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        err "openssl not found on PATH. Install OpenSSL >= 1.1.1."
        failures=$((failures + 1))
    else
        local ssl_banner ssl_flavor ssl_version ssl_min
        ssl_banner="$(openssl version)"
        ssl_flavor="$(awk '{print $1}' <<<"$ssl_banner")"
        ssl_version="$(awk '{print $2}' <<<"$ssl_banner")"
        case "$ssl_flavor" in
            OpenSSL) ssl_min="1.1.1" ;;
            LibreSSL) ssl_min="3.0" ;;
            *)
                err "unrecognized TLS toolkit '${ssl_banner}'; OpenSSL >= 1.1.1 or LibreSSL >= 3.0 is required."
                failures=$((failures + 1))
                ssl_min=""
                ;;
        esac
        if [[ -n "$ssl_min" ]] && ! version_ge "$ssl_version" "$ssl_min"; then
            err "${ssl_flavor} ${ssl_version} is too old; >= ${ssl_min} is required."
            failures=$((failures + 1))
        fi
    fi

    if [[ $failures -gt 0 ]]; then
        err "${failures} tool check(s) failed; aborting before generating anything."
        exit 1
    fi
}

# inventory_password VAR: print the value of "VAR: value" from group_vars,
# stripping quotes and inline comments. Prints nothing when absent.
inventory_password() {
    sed -n "s/^${1}:[[:space:]]*//p" "$inventory_file" | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'
}

resolve_password() {
    local env_name="$1" var_name="$2" purpose="$3" value
    value="${!env_name:-$(inventory_password "$var_name")}"
    if [[ -z "$value" || "$value" == "replace_me" ]]; then
        err "no ${purpose} passphrase available: set the ${env_name} environment" \
            "variable or define ${var_name} in ${inventory_file}." \
            "The value must match what the services are deployed with."
        exit 1
    fi
    printf '%s' "$value"
}

refuse_existing() {
    local existing=()
    for f in "$@"; do
        [[ -e "$f" ]] && existing+=("$f")
    done
    if [[ ${#existing[@]} -gt 0 && "$force" != true ]]; then
        err "refusing to overwrite existing files (re-run with --force):"
        printf '  %s\n' "${existing[@]}" >&2
        exit 1
    fi
}

check_tools

pgp_password="$(resolve_password PGP_KEY_PASSWORD pgp_key_password "GPG keyring")"
jwt_password="$(resolve_password JWT_SIGNING_KEY_PASSWORD jwt_signing_key_password "JWT signing key")"

keyring_file="${secrets_dir}/secring.gpg"
private_key_file="${secrets_dir}/signing_key/private-key.pem"
public_key_file="${secrets_dir}/signing_key/public-key.pem"
accepted_key_file="${secrets_dir}/accepted_keys/terrain.pem"

refuse_existing "$keyring_file" "$private_key_file" "$public_key_file" "$accepted_key_file"

mkdir -p "${secrets_dir}/signing_key" "${secrets_dir}/accepted_keys"

workdir="$(mktemp -d)"
cleanup() {
    for homedir in "${workdir}/gnupg" "${workdir}/verify"; do
        [[ -d "$homedir" ]] && gpgconf --homedir "$homedir" --kill gpg-agent >/dev/null 2>&1 || true
    done
    rm -rf "$workdir"
}
trap cleanup EXIT

info "Generating GPG keyring (RSA sign primary + RSA encrypt subkey)"
gpg_home="${workdir}/gnupg"
mkdir -p "$gpg_home"
chmod 700 "$gpg_home"
cat >"${workdir}/keyparams" <<EOF
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Subkey-Type: RSA
Subkey-Length: 2048
Subkey-Usage: encrypt
Name-Real: ${gpg_name}
Name-Email: ${gpg_email}
Expire-Date: 0
Passphrase: ${pgp_password}
%commit
EOF
gpg --homedir "$gpg_home" --batch --quiet --pinentry-mode loopback \
    --generate-key "${workdir}/keyparams"
gpg --homedir "$gpg_home" --batch --quiet --pinentry-mode loopback \
    --passphrase "$pgp_password" --export-secret-keys --armor >"$keyring_file"

info "Verifying the exported keyring imports cleanly"
verify_home="${workdir}/verify"
mkdir -p "$verify_home"
chmod 700 "$verify_home"
gpg --homedir "$verify_home" --batch --quiet --import "$keyring_file"
key_listing="$(gpg --homedir "$verify_home" --batch --list-secret-keys --with-colons)"
if ! grep -q '^sec:' <<<"$key_listing" || ! grep -q '^ssb:' <<<"$key_listing"; then
    err "exported keyring ${keyring_file} is missing the primary secret key or" \
        "the encryption subkey; this usually means the gpg batch generation failed."
    exit 1
fi

info "Generating JWT RSA signing keypair for terrain"
export _JWT_PASSPHRASE="$jwt_password"
openssl genrsa -aes256 -passout env:_JWT_PASSPHRASE -out "$private_key_file" 2048
openssl rsa -in "$private_key_file" -passin env:_JWT_PASSPHRASE \
    -pubout -out "$public_key_file"

info "Verifying the JWT keypair"
openssl rsa -check -noout -in "$private_key_file" -passin env:_JWT_PASSPHRASE >/dev/null
private_modulus="$(openssl rsa -noout -modulus -in "$private_key_file" -passin env:_JWT_PASSPHRASE)"
public_modulus="$(openssl rsa -noout -modulus -pubin -in "$public_key_file")"
unset _JWT_PASSPHRASE
if [[ "$private_modulus" != "$public_modulus" ]]; then
    err "generated public key does not match the private key; this should never" \
        "happen and likely indicates a broken openssl installation."
    exit 1
fi

cp "$public_key_file" "$accepted_key_file"
chmod 600 "$keyring_file" "$private_key_file"

cat <<EOF

Generated files:
  ${keyring_file}
  ${private_key_file}
  ${public_key_file}
  ${accepted_key_file}

Ensure these variables are set in ${inventory_file}:

  secrets_loader_gpg_filepaths: ["secring.gpg"]
  secrets_loader_signing_keys_filepaths:
    - signing_key/private-key.pem
    - signing_key/public-key.pem
  secrets_loader_accepted_keys_filepaths:
    - accepted_keys/terrain.pem
  secrets_loader_load_ssl_secret: false # nothing mounts ssl-files

Then load the secrets into the cluster by re-running the configure-services
tag of kubernetes.yml.
EOF
