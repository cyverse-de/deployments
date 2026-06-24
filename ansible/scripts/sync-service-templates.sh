#!/usr/bin/env bash
# Sync per-service config templates from the sibling de-releases repo into each
# role's templates/ dir under ansible/roles/services/.
#
# Usage: sync-service-templates.sh [--dry-run|-n] [<de-releases-dir>]
# Override the de-releases location with the positional arg or $DE_RELEASES_DIR.
# Default assumes both repos are checked out under the same parent directory.
#
# Matching is by basename: each role already owns a template named after the
# de-releases file it came from (e.g. de-mailer/templates/emailservice.yml.j2 <->
# de-releases/templates/emailservice.yml.j2), so no name-mapping table is needed.
# For every roles/services/*/templates/*.j2 we look up the same-named file under
# de-releases/templates/ and copy it ONLY when the contents differ.
#
# Pass --dry-run (or set DRY_RUN=1) to report what would change without writing.
#
# de-releases templates that match no role template (e.g. grouper-*, the de-/legacy
# test-vars, vice-default-backend.yml.j2) are not synced; they are listed at the end
# so they stay visible.
set -euo pipefail

log()  { printf '[sync-service-templates] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

DRY_RUN="${DRY_RUN:-0}"
positional=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    *) positional+=("$arg") ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../roles/services"
DE_RELEASES="${positional[0]:-${DE_RELEASES_DIR:-$SCRIPT_DIR/../../../de-releases}}"
TEMPLATES_DIR="$DE_RELEASES/templates"

[ -d "$TEMPLATES_DIR" ] || fail "missing $TEMPLATES_DIR"

declare -A matched=()
updated=0
unchanged=0
no_source=0

for role_template in "$ROLES_DIR"/*/templates/*.j2; do
  [ -e "$role_template" ] || continue
  name="$(basename "$role_template")"
  src="$TEMPLATES_DIR/$name"
  role="$(basename "$(dirname "$(dirname "$role_template")")")"

  if [ ! -f "$src" ]; then
    log "no source: $role/$name (no $name in de-releases)"
    no_source=$((no_source + 1))
    continue
  fi

  matched["$name"]=1

  if cmp -s "$src" "$role_template"; then
    unchanged=$((unchanged + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would update: $role/$name"
  else
    cp "$src" "$role_template"
    log "updated: $role/$name"
  fi
  updated=$((updated + 1))
done

orphans=()
for src in "$TEMPLATES_DIR"/*.j2; do
  [ -e "$src" ] || continue
  name="$(basename "$src")"
  [ -n "${matched[$name]:-}" ] || orphans+=("$name")
done

log ""
if [ "$DRY_RUN" -eq 1 ]; then
  log "summary (dry-run): would update $updated, unchanged $unchanged, no source $no_source"
else
  log "summary: updated $updated, unchanged $unchanged, no source $no_source"
fi

if [ "${#orphans[@]}" -gt 0 ]; then
  log "not synced (no matching role template): ${orphans[*]}"
fi
