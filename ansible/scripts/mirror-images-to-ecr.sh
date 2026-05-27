#!/usr/bin/env bash
# Mirror VICE images from an upstream registry (default harbor.cyverse.org)
# into the per-cluster ECR repos created by setup-ecr-repos.sh.
#
# Uses skopeo so:
#   - the bytes don't transit your workstation's disk
#   - multi-arch manifest lists are preserved (--all)
#   - one ECR login covers the whole run
#
# Required environment variables:
#   AWS_REGION         AWS region the ECR registry lives in
#   ECR_REPOS_FILE     Path to a file with one repo per line. Same format
#                      as setup-ecr-repos.sh, with one extra: each line may
#                      optionally include a tag (e.g. "de/porklock:v1.2"),
#                      which overrides $TAG for that line. Blank lines and
#                      '#' comments are ignored.
#
# Optional:
#   SRC_REGISTRY       Upstream registry hostname (default harbor.cyverse.org)
#   TAG                Default image tag when a repo line has no :tag
#                      (default "latest")
#   HARBOR_USER        Upstream registry username; together with HARBOR_PASSWORD
#   HARBOR_PASSWORD    triggers a skopeo login against $SRC_REGISTRY.
#                      Omit both to rely on existing skopeo / docker auth
#                      (or anonymous, for fully public source repos).
#
# Usage:
#   AWS_REGION=us-east-1 \
#   ECR_REPOS_FILE=repos.txt \
#   HARBOR_USER='robot$mirror' \
#   HARBOR_PASSWORD=xxxx \
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

if [[ ! -r "$ECR_REPOS_FILE" ]]; then
  fail "ECR_REPOS_FILE not readable: $ECR_REPOS_FILE"
fi

SRC_REGISTRY="${SRC_REGISTRY:-harbor.cyverse.org}"
TAG="${TAG:-latest}"

AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Always re-login to ECR — the token expires after 12 hours and there's
# no harm in refreshing it on every run.
log "logging into ${ECR_REGISTRY}"
aws ecr get-login-password --region "$AWS_REGION" \
  | skopeo login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

if [[ -n "${HARBOR_USER-}" && -n "${HARBOR_PASSWORD-}" ]]; then
  log "logging into ${SRC_REGISTRY}"
  printf '%s' "$HARBOR_PASSWORD" \
    | skopeo login --username "$HARBOR_USER" --password-stdin "$SRC_REGISTRY" >/dev/null
else
  log "HARBOR_USER/HARBOR_PASSWORD not set; relying on existing skopeo/docker auth for ${SRC_REGISTRY}"
fi

# Parse the repo file: take the first whitespace-delimited token from each
# non-blank, non-comment line.
mapfile -t lines < <(awk 'NF && $1 !~ /^#/ {print $1}' "$ECR_REPOS_FILE")
if [[ ${#lines[@]} -eq 0 ]]; then
  fail "no repos found in $ECR_REPOS_FILE"
fi

log "mirroring ${#lines[@]} image(s) from ${SRC_REGISTRY} to ${ECR_REGISTRY}"

failed=()
for line in "${lines[@]}"; do
  if [[ "$line" == *":"* ]]; then
    repo="${line%:*}"
    tag="${line##*:}"
  else
    repo="$line"
    tag="$TAG"
  fi

  src="docker://${SRC_REGISTRY}/${repo}:${tag}"
  dst="docker://${ECR_REGISTRY}/${repo}:${tag}"
  log "copying ${repo}:${tag}"
  if skopeo copy --all --retry-times 3 "$src" "$dst" >/dev/null; then
    log "  ok"
  else
    log "  FAILED"
    failed+=("${repo}:${tag}")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  log "completed with ${#failed[@]} failure(s):"
  for f in "${failed[@]}"; do
    log "  $f"
  done
  exit 1
fi

log "all ${#lines[@]} image(s) mirrored successfully"
