#!/usr/bin/env bash
# Sync per-service build descriptors and service files from the sibling
# de-releases repo into each role's files/ dir under ansible/roles/services/.
#
# Usage: sync-service-files.sh [--with-k8s] [--builds-only] [<de-releases-dir>]
# Override the de-releases location with the positional arg or $DE_RELEASES_DIR.
# Default assumes both repos are checked out under the same parent directory.
#
# By default the k8s manifests under services/<name>/k8s/ are NOT copied: each
# role now owns its own k8s manifest (e.g. to point at a per-service config
# secret), so syncing would clobber those edits. Pass --with-k8s (or set
# SYNC_K8S=1) to restore copying the k8s manifests from de-releases.
#
# Pass --builds-only (or set BUILDS_ONLY=1) to copy only the build JSON
# descriptors, skipping the service files and k8s dir. In this mode a build
# JSON is copied only when it differs from the role's current copy (new or
# changed), so unchanged roles are left untouched. --with-k8s is ignored here.
#
# Note: per-service config templates are not synced here. de-releases template
# names don't map 1:1 to service names (and some templates are shared by several
# services), so copying them into roles needs an explicit name mapping. Until
# that exists, copy a service's template into its role's templates/ dir by hand.
set -euo pipefail

WITH_K8S="${SYNC_K8S:-0}"
BUILDS_ONLY="${BUILDS_ONLY:-0}"
positional=()
for arg in "$@"; do
  case "$arg" in
    --with-k8s) WITH_K8S=1 ;;
    --builds-only) BUILDS_ONLY=1 ;;
    *) positional+=("$arg") ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../roles/services"
DE_RELEASES="${positional[0]:-${DE_RELEASES_DIR:-$SCRIPT_DIR/../../../de-releases}}"

[ -d "$DE_RELEASES/builds" ]   || { echo "missing $DE_RELEASES/builds"   >&2; exit 1; }
[ -d "$DE_RELEASES/services" ] || { echo "missing $DE_RELEASES/services" >&2; exit 1; }

# Roles with no build JSON of their own in de-releases because they ship from
# another service's image. Map each to the build it should track so its build
# JSON stays in sync with that source (vice-operator runs the app-exposer image).
declare -A BUILD_ALIAS=(
  [vice-operator]=app-exposer
)

missing=()
for role_dir in "$ROLES_DIR"/*/; do
  name="$(basename "$role_dir")"
  build_src="$DE_RELEASES/builds/${BUILD_ALIAS[$name]:-$name}.json"
  service_src="$DE_RELEASES/services/${name}"
  if [ ! -f "$build_src" ]; then
    missing+=("$name")
    continue
  fi
  files_dir="${role_dir}files"
  mkdir -p "$files_dir"
  build_dst="$files_dir/${name}.json"

  if [ "$BUILDS_ONLY" -eq 1 ]; then
    # Copy the build JSON only when new or changed; leave everything else alone.
    if cmp -s "$build_src" "$build_dst"; then
      continue
    fi
    cp "$build_src" "$build_dst"
    echo "synced build: $name"
    continue
  fi

  cp "$build_src" "$build_dst"
  if [ ! -d "$service_src" ]; then
    # No service dir in de-releases (e.g. vice-operator ships app-exposer's
    # image); the role owns its service files, so sync the build JSON only.
    echo "synced build only (no service dir): $name"
    continue
  fi
  # Copy top-level service files (skaffold.yaml, etc.), but never the k8s dir here.
  find "$service_src" -mindepth 1 -maxdepth 1 ! -name k8s -exec cp -R {} "$files_dir/" \;
  if [ "$WITH_K8S" -eq 1 ] && [ -d "$service_src/k8s" ]; then
    cp -R "$service_src/k8s" "$files_dir/"
  fi
  echo "synced: $name"
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo
  echo "skipped (no entry in de-releases): ${missing[*]}" >&2
fi
