---
name: caching-vice-images-in-aws
description: Use when caching, mirroring, or pre-loading a VICE image for an EKS cluster whose vice-operator runs in manual-mirror image cache mode — e.g. "cache this Harbor image in the EKS cluster", "mirror an image to ECR", or adding an entry to the vice-operator repos.json.
---

# Caching VICE Images in AWS

## Overview

EKS Auto Mode nodes are short-lived, so pre-pulling images onto nodes (the
kube-fledged `image_cache` role, or the legacy `vice_image_cache.yml`) doesn't
help there. Instead, EKS clusters run vice-operator with
`image_cache_mode: manual-mirror`:

1. Images are copied from Harbor into per-cluster **ECR** repos. ECR can't
   use a self-hosted Harbor as a pull-through upstream, so this is a direct
   push.
2. vice-operator reads a mapping file at startup and, at launch time,
   rewrites any image ref that has a mapping to its ECR copy. Unmapped images
   pass through unchanged.

One file drives all three steps:
`ansible/roles/services/vice-operator/files/repos.json`. It's a flat JSON
object of `{"<upstream ref>": "<fully qualified ECR ref>"}`.

**Run the scripts from `ansible/scripts/` and the playbook from `ansible/`.**

## When to Use

- Making a new or updated Harbor image fast to launch on an EKS cluster
- Checking that the cluster's inventory sets `image_cache_mode: manual-mirror`
  first. If it's `daemonset` or `cron`, this skill doesn't apply.
- NOT for non-EKS clusters (use the `image_cache` role, tag `image-cache`, in
  `kubernetes.yml`)

## Prerequisites

- `aws`, `skopeo`, and `jq` on `PATH`; Ansible with `kubernetes.core`
  (see `deploying-de-services`)
- AWS credentials for the account that owns the cluster's ECR registry
- Pull access to the upstream registry, either through existing
  skopeo/docker auth or via `UPSTREAM_USER` / `UPSTREAM_PASSWORD`. Never put
  credentials on the command line in anything you commit or share.
- The target inventory and kubeconfig. **REQUIRED SUB-SKILL:**
  `resolving-the-kubeconfig`. EKS inventories often don't set `kubeconfig`,
  so pass it with `-e kubeconfig=<path>`.

## Procedure

### 1. Check the inputs

```bash
skopeo inspect --raw docker://<upstream-ref> | jq '.mediaType, (.manifests // [] | length)'
aws sts get-caller-identity --query Account --output text
printenv AWS_ACCOUNT_ID
```

- Use the image ref exactly as analyses reference it: no `http://` or
  `https://` scheme. The key has to match the analysis's image ref exactly,
  or the operator won't rewrite it.
- **Both scripts prefer `AWS_ACCOUNT_ID` over the caller identity.** If it's
  set to a different account, `mirror-images-to-ecr.sh` pushes to that
  account's registry. (`setup-ecr-repos.sh` only logs it.) Unset it, or set it
  explicitly to the account `sts` reports.

### 2. Add the mapping

Add the entry to `repos.json`, keeping the file's existing grouping (entries
are grouped by upstream project):

```json
"harbor.cyverse.org/<project>/<name>:<tag>" : "<account>.dkr.ecr.<region>.amazonaws.com/<project>/<name>:<tag>"
```

The ECR repo name comes from the value: strip the registry host and the tag.

### 3. Create the ECR repo and copy the image

To copy only the new image instead of re-running the whole file, extract
just the new entry into a scratch file:

```bash
jq --arg k '<upstream-ref>' '{($k): .[$k]}' \
  ../roles/services/vice-operator/files/repos.json > "$SCRATCH/one-image.json"

AWS_REGION=<region> ECR_REPOS_FILE="$SCRATCH/one-image.json" \
  EKS_CLUSTER_NAME=<cluster-name> ./setup-ecr-repos.sh

AWS_ACCOUNT_ID=<account> AWS_REGION=<region> ECR_REPOS_FILE="$SCRATCH/one-image.json" \
  ./mirror-images-to-ecr.sh
```

- `setup-ecr-repos.sh` can be re-run safely. It creates the repos, applies
  the lifecycle policy, and sets the node role's `ECRImageCachePull` inline
  policy. That policy grants `Resource: "*"`, so a subset run doesn't remove
  pull access to other repos.
- `mirror-images-to-ecr.sh` runs `skopeo copy --all` for each entry, so
  multi-arch indexes are preserved. skopeo skips layers ECR already has, so
  re-running the full file is mostly cheap, but each image still costs a
  round of registry requests.

### 4. Wait for the copy to finish

The copy streams every byte through your machine (download from Harbor and
upload to ECR at once). A multi-GB image can take **over an hour** on a
workstation connection, so run it in the background.

- **Nothing shows up in ECR until the end.** skopeo pushes the manifests and
  the tag only after all layers are uploaded, so an empty
  `aws ecr describe-images` mid-copy doesn't mean it's stuck.
- To check progress, sample the process's read counter twice and compare
  against the sum of compressed layer sizes. The counter includes some
  overhead, so it slightly overstates progress.
  ```bash
  awk '/^rchar/{print $2}' /proc/$(pgrep -f 'skopeo copy')/io
  ```
- **Check that the copy succeeded.** Look for
  `all N image(s) mirrored successfully` in the output, and the tag in
  `aws ecr describe-images --repository-name <project>/<name>`. Don't pipe the
  script through `tail` and trust the exit code, which would be `tail`'s.

### 5. Redeploy vice-operator so it loads the mapping

**Only after the copy succeeds.** If the operator rewrites to an ECR image
that isn't there yet, launches of that image fail with `ImagePullBackOff`.

```bash
ansible-playbook -i <inventory> vice-operator-eks.yml --tags vice-operator \
  -e kubeconfig=<path>
kubectl --kubeconfig <path> -n <vice_ns> rollout restart deploy/vice-operator
kubectl --kubeconfig <path> -n <vice_ns> rollout status deploy/vice-operator
```

The playbook updates the `vice-operator-repos` ConfigMap, but the Deployment
has no checksum annotation and the operator reads the file only at startup,
so **the restart is required**. The playbook also redeploys everything else
in the role from this checkout, so make sure that's what you want on the
cluster.

### 6. Verify

```bash
kubectl --kubeconfig <path> -n <vice_ns> get cm vice-operator-repos \
  -o jsonpath='{.data.repos}' | grep '<name>'
kubectl --kubeconfig <path> -n <vice_ns> get pods
```

- A running pod means the mapping file parsed: the operator refuses to start
  with an invalid file.
- `GET /image-cache` lists the mappings but needs a Keycloak bearer token.
  The operator image has no shell, so you can't `exec ... cat` the mounted
  file.
- The real confirmation comes at the next launch of the image: the operator
  logs `rewrote N image ref(s) for analysis <id>`, and the analysis
  Deployment shows the ECR image ref.

### 7. Commit

Commit the `repos.json` change so the next redeploy doesn't drop the entry.
Don't commit the scratch file.

## Common Mistakes

- **Including a URL scheme in the key.** Write `harbor.cyverse.org/...`, not
  `http://harbor.cyverse.org/...`.
- **A stale `AWS_ACCOUNT_ID` in the shell.** It sends the mirror to the wrong
  registry, while `setup-ecr-repos.sh` creates the repo in the right one.
- **Redeploying before the copy finishes.** The operator rewrites to an image
  that doesn't exist yet.
- **Skipping the rollout restart.** The ConfigMap changes, but the running
  operator keeps the old mapping.
- **Not committing `repos.json`.** The next vice-operator deploy from a clean
  checkout removes the mapping, and launches go back to pulling from Harbor.
- **Too many tags in one repo.** The lifecycle policy keeps
  `LIFECYCLE_TAGGED_COUNT` (default 10) images per repo. If you mirror many
  tags of the same image, older mapped tags can expire out from under their
  `repos.json` entries.
