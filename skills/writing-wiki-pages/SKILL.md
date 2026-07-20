---
name: writing-wiki-pages
description: Use when creating or editing a concept page in the OKF wiki at wiki/ — frontmatter shape, type vocabulary, link style, and log/index upkeep; e.g. "add a wiki page about rabbitmq" or "update the postgres wiki page".
---

# Writing Wiki Pages

## Overview

The repo has a curated knowledge wiki at `wiki/`, an
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
v0.1 bundle. Every `.md` file except the reserved `index.md` and `log.md` is a
**concept page**: YAML frontmatter (with a required `type`) followed by a
markdown body. Subdirectory `index.md` files are **generated** by the `okf`
tool; `wiki/index.md` (bundle root) and `wiki/log.md` are hand-maintained.

## When to Use

- Creating a brand-new concept page, or editing an existing one's frontmatter
  or body.
- NOT for converting an existing repo doc into a wiki page — see
  `migrating-docs-to-wiki`.
- NOT for looking up answers in the wiki — see `searching-the-wiki`.
- NOT for running the validator or fixing its findings — see
  `validating-the-wiki` (but you must run it after any edit; see below).

## Quick Reference

Frontmatter template for a new page:

```yaml
---
type: Service
title: Human-Readable Name
description: One sentence used in indexes and search snippets.
resource: /ansible/path/to/authoritative/file
tags: [lowercase, keywords]
timestamp: 2026-07-20T00:00:00Z
---
```

`type` vocabulary used in this wiki (free-form per spec, but stay consistent):

| `type` | Use for | Lives under |
| --- | --- | --- |
| `Service` | A deployed backing system or DE microservice | `infrastructure/`, `services/` |
| `Runbook` | A procedure or workflow an operator follows | `playbooks/` |
| `Playbook` | A single Ansible playbook's concept page | `playbooks/` |

Link style inside page bodies:

| Target | Form | Example |
| --- | --- | --- |
| Another wiki page | Bundle-absolute (preferred) | `[NATS](/infrastructure/nats.md)` |
| Sibling page | Relative is allowed | `[NATS](./nats.md)` |
| Repo file outside `wiki/` | Plain code span, never a markdown link | `` `ansible/roles/nats/` `` |
| External source | Full URL | `[spec](https://example.org/spec)` |

## Writing a Page

1. Pick the directory (`infrastructure/`, `playbooks/`, `services/`) and a
   lowercase-kebab filename; the path minus `.md` becomes the concept ID.
2. Write the frontmatter from the template. `type` is required and must be
   non-empty; `title`, `description`, and `timestamp` are lint-checked. Set
   `timestamp` to now (ISO 8601) on every meaningful edit.
3. Write the body. Cite sources at the bottom under a `# Citations` heading —
   repo paths as plain code spans, external material as URLs.
4. Add an entry to `wiki/log.md` under a `## YYYY-MM-DD` heading for today.
   Newest date group goes **first**; add to the existing group if today's
   already there.
5. Regenerate indexes and validate.

**REQUIRED SUB-SKILL:** after any wiki edit, run `validating-the-wiki` — the
edit is not done until `okf index` has been run and `okf check` reports 0
errors and 0 warnings.

## Common Mistakes

- **Putting frontmatter in `index.md` or `log.md`.** Reserved files take no
  frontmatter (only the bundle root `wiki/index.md` carries `okf_version`).
  A dated entry in `log.md` is the changelog; a concept page's own metadata
  lives in its frontmatter.
- **Hand-editing a subdirectory `index.md`.** They are generated from concept
  frontmatter; the validator flags drift (OKF106). Fix the page's `title`/
  `description` and re-run `okf index` instead.
- **Leaving `type` empty or missing.** It's the only hard-required field
  (OKF003); pick from the vocabulary table above.
- **Linking to files outside `wiki/`.** A markdown link that escapes the bundle
  is flagged (OKF108); use the `resource` field or a plain code-span path in
  Citations.
- **Forgetting the log entry.** Every meaningful change gets a line in
  `wiki/log.md`, newest-first.
