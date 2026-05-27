#!/usr/bin/env bash
# Mirror VICE images into the per-cluster ECR repos created by
# setup-ecr-repos.sh, driven by the same JSON file that vice-operator's
# --repos-file accepts.
#
# Uses skopeo so:
#   - the bytes don't transit your workstation's disk
#   - multi-arch manifest lists are preserved (--all)
#   - one ECR login covers the whole run
#
# Prerequisites: aws, skopeo, jq.
#
# Required environment variables:
#   AWS_REGION         AWS region the ECR registry lives in
#   ECR_REPOS_FILE     Path to a JSON object mapping upstream image refs to
#                      fully-qualified mirrored refs. Both sides are
#                      complete, pullable refs; this script copies each
#                      key -> value pair verbatim.
#                      Example:
#                        {
#                          "harbor.cyverse.org/de/vice-proxy:latest":
#                            "123456789012.dkr.ecr.us-east-1.amazonaws.com/de/vice-proxy:latest",
#                          "harbor.cyverse.org/de/porklock:qa":
#                            "123456789012.dkr.ecr.us-east-1.amazonaws.com/de/porklock:qa"
#                        }
#
# Optional:
#   UPSTREAM_USER      Username for the upstream registry; together with
#   UPSTREAM_PASSWORD  UPSTREAM_PASSWORD triggers a skopeo login against
#                      the upstream host (auto-detected from the first
#                      JSON key). Omit both to rely on existing skopeo /
#                      docker auth, or for fully public source repos.
#
# Usage:
#   AWS_REGION=us-east-1 \
#   ECR_REPOS_FILE=repos.json \
#   UPSTREAM_USER='robot$mirror' \
#   UPSTREAM_PASSWORD=xxxx \
#     ./mirror-images-to-ecr.sh

set -euo pipefail

log()  { printf '[mirror-images-to-ecr] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

require() {
  local name="$1"
  if [[ -z "${!name-}" ]]; then
    fail "missing required env var: $name"
  fi
}

require AWS_REGION
require ECR_REPOS_FILE

command -v skopeo >/dev/null \
  || fail "skopeo not found in PATH; install via 'brew install skopeo' / 'dnf install skopeo' / 'apt install skopeo'"
command -v jq >/dev/null \
  || fail "jq not found in PATH; install via 'dnf install jq' / 'brew install jq' / 'apt install jq'"

if [[ ! -r "$ECR_REPOS_FILE" ]]; then
  fail "ECR_REPOS_FILE not readable: $ECR_REPOS_FILE"
fi

file_type=$(jq -er 'type' "$ECR_REPOS_FILE" 2>/dev/null || true)
if [[ "$file_type" != "object" ]]; then
  fail "$ECR_REPOS_FILE must be a JSON object of {upstream: mirrored} (got: ${file_type:-unparseable})"
fi

AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Always re-login to ECR — the token expires after 12 hours and there's
# no harm in refreshing it on every run.
log "logging into ${ECR_REGISTRY}"
aws ecr get-login-password --region "$AWS_REGION" \
  | skopeo login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

# When upstream creds are provided, log in against the host of the first
# JSON key. If the file mixes multiple upstream hosts under one login,
# the other hosts may fail their pulls — caller can split the file or
# pre-login separately.
if [[ -n "${UPSTREAM_USER-}" && -n "${UPSTREAM_PASSWORD-}" ]]; then
  upstream_host=$(jq -r 'keys[0] | split("/")[0]' "$ECR_REPOS_FILE")
  if [[ -z "$upstream_host" || "$upstream_host" == "null" ]]; then
    fail "could not derive upstream host from $ECR_REPOS_FILE"
  fi
  log "logging into ${upstream_host}"
  printf '%s' "$UPSTREAM_PASSWORD" \
    | skopeo login --username "$UPSTREAM_USER" --password-stdin "$upstream_host" >/dev/null
  if [[ $(jq -r '[keys[] | split("/")[0]] | unique | length' "$ECR_REPOS_FILE") -gt 1 ]]; then
    log "WARNING: $ECR_REPOS_FILE references multiple upstream hosts; logged in only to ${upstream_host}"
  fi
else
  log "UPSTREAM_USER/UPSTREAM_PASSWORD not set; relying on existing skopeo/docker auth for upstream pulls"
fi

# Stream tab-separated (upstream, mirror) pairs from the JSON. Use a
# process substitution rather than a pipeline so the loop body runs in
# the current shell — necessary for the failed=() accumulator to
# survive past the loop.
mapfile -t pairs < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ECR_REPOS_FILE")
if [[ ${#pairs[@]} -eq 0 ]]; then
  fail "no entries in $ECR_REPOS_FILE"
fi

log "mirroring ${#pairs[@]} image(s) into ${ECR_REGISTRY}"

failed=()
for pair in "${pairs[@]}"; do
  IFS=$'\t' read -r upstream mirror <<< "$pair"
  log "copying ${upstream} -> ${mirror}"
  if skopeo copy --all --retry-times 3 \
       "docker://${upstream}" "docker://${mirror}" >/dev/null; then
    log "  ok"
  else
    log "  FAILED"
    failed+=("$upstream")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  log "completed with ${#failed[@]} failure(s):"
  for f in "${failed[@]}"; do
    log "  $f"
  done
  exit 1
fi

log "all ${#pairs[@]} image(s) mirrored successfully"
