#!/usr/bin/env bash
# Custom skaffold builder. skaffold runs this with IMAGE, PUSH_IMAGE,
# BUILD_CONTEXT and PLATFORMS set in the environment.
#
# It builds with `docker buildx` so it can read and write a mode=max registry
# layer cache (the `<image>:cache` tag). mode=max caches every build stage,
# including the dependency-download stage of multi-stage builds, so Clojure
# (Maven/Clojars) and similar dependency trees are reused across builds instead
# of being re-fetched from upstream every time.
#
# Cache export (--cache-to type=registry) needs a container-driver buildx
# builder; the default `docker` driver cannot export a registry cache. Export
# only happens on a push build, so build-only/verify runs work on any builder.
set -euo pipefail

cache_ref="${IMAGE%:*}:cache"

args=(
  buildx build
  --tag "$IMAGE"
  --platform "${PLATFORMS:-linux/amd64}"
  --file "${BUILD_CONTEXT}/Dockerfile"
  --cache-from "type=registry,ref=${cache_ref}"
  # A provenance attestation turns the pushed artifact into an OCI image index
  # even for a single-platform build; keep it a plain image manifest so the
  # descriptor digests (tag@sha256:...) keep pointing at the image itself.
  --provenance=false
)

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  args+=(--cache-to "type=registry,ref=${cache_ref},mode=max" --push)
else
  args+=(--load)
fi

args+=("$BUILD_CONTEXT")

exec docker "${args[@]}"
