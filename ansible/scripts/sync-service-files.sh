#!/usr/bin/env bash
# Sync per-service build descriptors and service files from the sibling
# de-releases repo into each role's files/ dir under ansible/roles/services/.
#
# Usage: sync-service-files.sh [<de-releases-dir>]
# Override default location with $1 or $DE_RELEASES_DIR. Default assumes both
# repos are checked out under the same parent directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../roles/services"
DE_RELEASES="${1:-${DE_RELEASES_DIR:-$SCRIPT_DIR/../../../de-releases}}"

[ -d "$DE_RELEASES/builds" ]   || { echo "missing $DE_RELEASES/builds"   >&2; exit 1; }
[ -d "$DE_RELEASES/services" ] || { echo "missing $DE_RELEASES/services" >&2; exit 1; }

missing=()
for role_dir in "$ROLES_DIR"/*/; do
  name="$(basename "$role_dir")"
  build_src="$DE_RELEASES/builds/${name}.json"
  service_src="$DE_RELEASES/services/${name}"
  if [ ! -f "$build_src" ] || [ ! -d "$service_src" ]; then
    missing+=("$name")
    continue
  fi
  files_dir="${role_dir}files"
  mkdir -p "$files_dir"
  cp "$build_src" "$files_dir/${name}.json"
  cp -R "$service_src/." "$files_dir/"
  echo "synced: $name"
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo
  echo "skipped (no entry in de-releases): ${missing[*]}" >&2
fi
