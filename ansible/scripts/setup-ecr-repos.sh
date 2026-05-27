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
# Required environment variables:
#   AWS_REGION         AWS region the EKS cluster runs in (e.g. us-east-1)
#   ECR_REPOS_FILE     Path to a file with one repo per line. Each line may
#                      optionally include a ":tag" suffix (e.g.
#                      "de/vice-proxy:latest") — the tag is stripped here
#                      since ECR repos are tag-agnostic. Same file works
#                      with mirror-images-to-ecr.sh, which honors the tag.
#                      Blank lines and '#' comments are ignored. Duplicate
#                      repos (after tag-stripping) are de-duped.
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
#   ECR_REPOS_FILE=repos.txt \
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

if [[ ! -r "$ECR_REPOS_FILE" ]]; then
  fail "ECR_REPOS_FILE not readable: $ECR_REPOS_FILE"
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

# Parse the repo file: take the first whitespace-delimited token from each
# non-blank, non-comment line, strip any ":tag" suffix (ECR repo names
# don't carry tags), and de-dupe while preserving first-occurrence order.
mapfile -t repos < <(
  awk 'NF && $1 !~ /^#/ { sub(/:.*/, "", $1); if (!seen[$1]++) print $1 }' "$ECR_REPOS_FILE"
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
