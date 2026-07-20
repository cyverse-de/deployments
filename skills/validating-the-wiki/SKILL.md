---
name: validating-the-wiki
description: Use when checking the OKF wiki for conformance or regenerating its index files — after any wiki/ edit, or when asked to "check the wiki"; runs and interprets `uv run okf check` and `uv run okf index` from scripts/okf.
---

# Validating the Wiki

## Overview

`scripts/okf/` is a uv-managed Python CLI that validates the OKF bundle at
`wiki/` and generates its subdirectory `index.md` files. `okf check` reports
conformance **ERRORs** (violations of the OKF spec) and lint **WARNs** (dead
links, missing recommended fields, index drift, log ordering, link style).

## When to Use

- After every edit made under `writing-wiki-pages` or `migrating-docs-to-wiki`.
- When asked to check, lint, or fix the wiki.
- NOT for reviewing page content or prose quality — this is structural
  validation only.

## Quick Reference

```bash
cd scripts/okf

# Validate the whole bundle
uv run okf check ../../wiki

# Regenerate subdirectory index.md files (never touches wiki/index.md)
uv run okf index ../../wiki

# Report index drift without writing
uv run okf index --check ../../wiki

# Machine-readable output; treat warnings as failures
uv run okf check --format json ../../wiki
uv run okf check --strict ../../wiki
```

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | No errors (warnings allowed unless `--strict`) |
| 1 | Errors found; or warnings with `--strict`; or drift with `index --check` |
| 2 | Usage/environment problem (path isn't an OKF bundle root) |

## Interpreting Findings

Findings print as `file:line: SEVERITY CODE message`, sorted by file.

| Code | Severity | Meaning / fix |
| --- | --- | --- |
| OKF001 | ERROR | Concept page has no frontmatter block — add one. |
| OKF002 | ERROR | Frontmatter isn't valid YAML or isn't a mapping — fix the YAML. |
| OKF003 | ERROR | `type` missing/non-string/empty — set it (see `writing-wiki-pages`). |
| OKF004 | ERROR | Frontmatter in a subdirectory `index.md`, or root `okf_version` malformed — remove it / quote the version (`"0.1"`). |
| OKF005 | ERROR | Frontmatter in `log.md` — remove it. |
| OKF006 | ERROR | `log.md` structure invalid — one `# ` title, then `## YYYY-MM-DD` groups only. |
| OKF007 | ERROR | File can't be read (permissions or not UTF-8) — fix the file; its other checks are skipped. |
| OKF101 | WARN | Dead internal link — fix the path, or accept it as intentionally unwritten knowledge. |
| OKF102/103 | WARN | Missing `title`/`description` — add them; indexes are built from them. |
| OKF104 | WARN | `timestamp` missing or not ISO 8601. |
| OKF105 | WARN | `tags` isn't a list of strings. |
| OKF106 | WARN | Subdirectory index missing or stale — run `uv run okf index ../../wiki`. |
| OKF107 | WARN | `log.md` date groups not newest-first — reorder. |
| OKF108 | WARN | Link escapes the bundle — use a plain code-span path or `resource` instead. |
| OKF109 | WARN | Upward-relative link (`../x.md`) — use the bundle-absolute form it suggests. |
| OKF110 | WARN | Symlinked directory — its contents are invisible to validation and indexing; use a real directory. |

## Common Mistakes

- **Stopping while ERRORs remain.** ERRORs are spec violations and must reach
  zero. WARNs are judgment calls — a dead link may be deliberate (OKF tolerates
  links to not-yet-written pages) — but this wiki aims for warning-clean, so
  explain any WARN you leave in place.
- **Fixing OKF106 by hand-editing the index.** Run `okf index`; edit the
  concept page's frontmatter if the entry text is wrong.
- **Running from the wrong directory.** `uv run` needs the project at
  `scripts/okf`; run `cd scripts/okf` first (or use
  `uv run --project scripts/okf okf check wiki` from the repo root).
