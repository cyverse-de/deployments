---
type: Runbook
title: Maintaining This Wiki
description: How to add, edit, migrate, and validate pages in this wiki — frontmatter rules, generated indexes, the update log, and the okf tool.
tags: [wiki, okf, meta]
timestamp: 2026-07-20T00:00:00Z
---

This wiki is an
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
v0.1 bundle rooted at `wiki/`. Every `.md` file except the reserved `index.md`
and `log.md` is a **concept page**. The wiki summarizes; each page's `resource`
field and `# Citations` section point at the authoritative files in the repo.

## Page anatomy

A concept page is YAML frontmatter followed by a markdown body:

```yaml
---
type: Service            # required, non-empty; Service | Runbook | Playbook
title: Human-Readable Name
description: One sentence; indexes and search snippets are built from this.
resource: /ansible/path/to/authoritative/file   # omit for abstract concepts
tags: [lowercase, keywords]
timestamp: 2026-07-20T00:00:00Z   # update on every meaningful change
---
```

Sections: `infrastructure/` for backing systems, `playbooks/` for procedures
and workflows, `services/` for DE microservices. Link wiki pages with
bundle-absolute paths (`/infrastructure/nats.md`); reference repo files outside
the wiki as plain code spans (`` `ansible/roles/nats/` ``), never markdown
links.

## Reserved files

- `index.md` — a directory listing. The root one (this bundle's entry point) is
  hand-maintained and carries the only permitted frontmatter, `okf_version`.
  **Subdirectory index files are generated** — never edit them by hand.
- `log.md` — the update history: one `# ` title, then `## YYYY-MM-DD` groups,
  newest first.

## Making a change

1. Create or edit the concept page; set `timestamp` to now.
2. Add a line to [the update log](/log.md) under today's date group
   (newest group first).
3. Regenerate indexes and validate:

```bash
cd scripts/okf
uv run okf index ../../wiki
uv run okf check ../../wiki
```

4. `okf check` must finish with **0 errors**; treat warnings as things to fix
   or consciously accept (a dead link can be deliberate — it marks a page worth
   writing). Findings print as `file:line: SEVERITY CODE message`; codes and
   fixes are tabulated in the `validating-the-wiki` skill and
   `scripts/okf/README.md`.

When converting an existing repo doc, migration is **copy, not move**: the
original stays put and becomes the page's `resource`.

## Tooling and skills

The validator/indexer lives at `scripts/okf/` (uv-managed Python; see its
README). For Claude Code, five repo skills cover wiki work —
`writing-wiki-pages`, `migrating-docs-to-wiki`, `searching-the-wiki`,
`validating-the-wiki`, and `updating-the-wiki` (the end-of-task staleness
check that fires after ordinary deployment work) — auto-loaded from
`.claude/skills/` (a symlink to `skills/`). The repo `CLAUDE.md` instructs
Claude Code to run the staleness check after any change to `ansible/`,
`kustomize/`, `notes/`, or `scripts/`, so wiki upkeep doesn't depend on being
asked.

# Citations

[1] [Open Knowledge Format specification](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) — the format this wiki conforms to.
[2] `scripts/okf/README.md` — tool usage, output format, exit codes.
[3] `skills/` — the five wiki skills for Claude Code.
