#!/usr/bin/env bash
# Set up per-cluster ECR repositories for the vice-operator cron-mode image
# cache (see app-exposer's
# docs/superpowers/specs/2026-05-27-image-cache-cron-mode-ecr.md).
#
# This script does NOT configure ECR pull-through cache — AWS does not
# support self-hosted Harbor as an upstream. Images are pushed into these
# repos directly by an out-of-band mirror or build job; the operator's
# cron-mode CronJobs then re-pull them so EKS Auto Mode nodes stay warm.
#
# Idempotent: safe to re-run. Each step checks for the existing resource
# and updates in place.
#
# Prerequisites: aws, jq.
#
# Required environment variables:
#   AWS_REGION         AWS region the EKS cluster runs in (e.g. us-east-1)
#   ECR_REPOS_FILE     Path to a JSON object mapping upstream image refs to
#                      fully-qualified mirrored refs. Same file format that
#                      vice-operator's --repos-file accepts and that
#                      mirror-images-to-ecr.sh consumes; single source of
#                      truth for all three callers. ECR repo names are
#                      derived from each value: strip the registry host
#                      and the tag, then de-dupe.
#                      Example:
#                        {
#                          "harbor.cyverse.org/de/vice-proxy:latest":
#                            "123456789012.dkr.ecr.us-east-1.amazonaws.com/de/vice-proxy:latest",
#                          "harbor.cyverse.org/de/porklock:qa":
#                            "123456789012.dkr.ecr.us-east-1.amazonaws.com/de/porklock:qa"
#                        }
#                      yields the ECR repos: de/vice-proxy, de/porklock.
#
# One of the following two must also be provided:
#   NODE_ROLE_NAME     EKS node IAM role name to grant pull perms to
#   EKS_CLUSTER_NAME   Cluster name; the script derives NODE_ROLE_NAME from it
#                      via "aws eks describe-cluster"
#
# Optional:
#   LIFECYCLE_UNTAGGED_DAYS   Days before untagged images expire (default 30)
#   LIFECYCLE_TAGGED_COUNT    Tagged-image count cap per repo (default 10)
#   IMAGE_TAG_MUTABILITY      MUTABLE or IMMUTABLE (default MUTABLE)
#
# Usage:
#   AWS_REGION=us-east-1 \
#   ECR_REPOS_FILE=repos.json \
#   EKS_CLUSTER_NAME=ua-ai-sandboxes \
#     ./setup-ecr-repos.sh

set -euo pipefail

log()  { printf '[setup-ecr-repos] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

require() {
  local name="$1"
  if [[ -z "${!name-}" ]]; then
    fail "missing required env var: $name"
  fi
}

require AWS_REGION
require ECR_REPOS_FILE

command -v jq >/dev/null \
  || fail "jq not found in PATH; install via 'dnf install jq' / 'brew install jq' / 'apt install jq'"

if [[ ! -r "$ECR_REPOS_FILE" ]]; then
  fail "ECR_REPOS_FILE not readable: $ECR_REPOS_FILE"
fi

# Confirm the file is a JSON object before any other parsing — gives a
# clear error instead of a confusing empty-list bail later.
file_type=$(jq -er 'type' "$ECR_REPOS_FILE" 2>/dev/null || true)
if [[ "$file_type" != "object" ]]; then
  fail "$ECR_REPOS_FILE must be a JSON object of {upstream: mirrored} (got: ${file_type:-unparseable})"
fi

if [[ -z "${NODE_ROLE_NAME-}" ]]; then
  if [[ -z "${EKS_CLUSTER_NAME-}" ]]; then
    fail "set either NODE_ROLE_NAME or EKS_CLUSTER_NAME so the node role can be located"
  fi
  log "looking up node role for EKS cluster ${EKS_CLUSTER_NAME}"
  node_role_arn=$(aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$EKS_CLUSTER_NAME" \
    --query 'cluster.computeConfig.nodeRoleArn' \
    --output text 2>/dev/null || true)
  if [[ -z "$node_role_arn" || "$node_role_arn" == "None" ]]; then
    fail "could not read cluster.computeConfig.nodeRoleArn for ${EKS_CLUSTER_NAME}; either the cluster isn't EKS Auto Mode, or your AWS CLI is too old. Set NODE_ROLE_NAME directly."
  fi
  NODE_ROLE_NAME="${node_role_arn##*/}"
  log "discovered NODE_ROLE_NAME=${NODE_ROLE_NAME}"
fi

AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}
LIFECYCLE_UNTAGGED_DAYS=${LIFECYCLE_UNTAGGED_DAYS:-30}
LIFECYCLE_TAGGED_COUNT=${LIFECYCLE_TAGGED_COUNT:-10}
IMAGE_TAG_MUTABILITY=${IMAGE_TAG_MUTABILITY:-MUTABLE}

if [[ "$IMAGE_TAG_MUTABILITY" != "MUTABLE" && "$IMAGE_TAG_MUTABILITY" != "IMMUTABLE" ]]; then
  fail "IMAGE_TAG_MUTABILITY must be MUTABLE or IMMUTABLE, got $IMAGE_TAG_MUTABILITY"
fi

# Derive ECR repo names from the JSON object values: strip the registry
# host (everything up to and including the first '/'), strip the tag
# (everything from the last ':' onwards — the path between registry and
# tag never contains ':'), then de-dupe in first-occurrence order so the
# final log lines come out in input order.
mapfile -t repos < <(
  jq -r '.[]' "$ECR_REPOS_FILE" \
    | sed -E 's|^[^/]+/||; s|:[^/]*$||' \
    | awk '!seen[$0]++'
)
if [[ ${#repos[@]} -eq 0 ]]; then
  fail "no repo names found in $ECR_REPOS_FILE"
fi
log "managing ${#repos[@]} repo(s) from $ECR_REPOS_FILE"

lifecycle_policy=$(cat <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire untagged images older than ${LIFECYCLE_UNTAGGED_DAYS} days",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": ${LIFECYCLE_UNTAGGED_DAYS}
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Keep at most ${LIFECYCLE_TAGGED_COUNT} tagged images per repo",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": ${LIFECYCLE_TAGGED_COUNT}
      },
      "action": { "type": "expire" }
    }
  ]
}
EOF
)

#
# Step 1: Create-or-update each ECR repository with the shared lifecycle
# policy. Re-runs re-apply the policy so tweaks to the env vars propagate
# to previously-created repos.
#
for repo in "${repos[@]}"; do
  if aws ecr describe-repositories \
       --region "$AWS_REGION" --repository-names "$repo" >/dev/null 2>&1; then
    log "repo ${repo} exists; re-applying lifecycle policy"
  else
    log "creating repo ${repo}"
    aws ecr create-repository \
      --region "$AWS_REGION" \
      --repository-name "$repo" \
      --image-tag-mutability "$IMAGE_TAG_MUTABILITY" \
      --tags Key=managed-by,Value=vice-operator-image-cache >/dev/null
  fi

  aws ecr put-lifecycle-policy \
    --region "$AWS_REGION" \
    --repository-name "$repo" \
    --lifecycle-policy-text "$lifecycle_policy" >/dev/null
done

#
# Step 2: Inline pull-only policy on the EKS node role. put-role-policy
# replaces in place, so this is naturally idempotent. We also remove the
# old ECRPullThroughCache policy left behind by the prior pull-through
# script, since its CreateRepository / BatchImportUpstreamImage grants
# are unnecessary now.
#
old_policy=$(aws iam get-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-name ECRPullThroughCache \
  --query PolicyName --output text 2>/dev/null || true)
if [[ "$old_policy" == "ECRPullThroughCache" ]]; then
  log "removing stale inline policy ECRPullThroughCache from role ${NODE_ROLE_NAME}"
  aws iam delete-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-name ECRPullThroughCache
fi

policy_doc=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

log "attaching inline policy ECRImageCachePull to role ${NODE_ROLE_NAME}"
aws iam put-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-name ECRImageCachePull \
  --policy-document "$policy_doc"

log "done"
log "account=${AWS_ACCOUNT_ID} region=${AWS_REGION} node-role=${NODE_ROLE_NAME}"
log "repo URIs (use these in PUT /image-cache):"
for repo in "${repos[@]}"; do
  log "  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${repo}:<tag>"
done
