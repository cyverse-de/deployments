---
name: migrating-docs-to-wiki
description: Use when converting an existing repo doc (ansible/docs/, ansible/BUILD_DEPLOY.md, notes/) into an OKF wiki concept page — choosing directory and type, adding frontmatter, wiring citations, and updating log and indexes; e.g. "move the rabbitmq doc into the wiki".
---

# Migrating Docs to the Wiki

## Overview

Existing prose docs (`ansible/docs/*.md`, `ansible/BUILD_DEPLOY.md`,
`notes/*.md`) can be converted into concept pages under `wiki/`. Migration is
**copy, not move**: the original stays in place and the wiki page's
`resource` field points back at it as the canonical source.
`wiki/infrastructure/postgresql.md`, `wiki/infrastructure/nats.md`, and
`wiki/playbooks/build-and-deploy.md` are worked examples of this conversion.

## When to Use

- Converting an existing repo doc into the wiki, wholesale or condensed.
- NOT for writing a brand-new page from scratch — see `writing-wiki-pages`.
- Never migrate `ansible/docs/index.md` — it's a table of contents, not a
  concept, and `index.md` is a reserved OKF filename.

**REQUIRED SUB-SKILL:** `writing-wiki-pages` for the frontmatter, type
vocabulary, and link rules; `validating-the-wiki` before calling the migration
done.

## Migration Procedure

1. Choose the target directory and `type` (see the vocabulary table in
   `writing-wiki-pages`), and a lowercase-kebab filename.
2. Copy the doc body. Drop the doc's `# ` title line — the wiki page's title
   lives in frontmatter. Long docs may be condensed (see
   `/playbooks/build-and-deploy.md`); short docs copy verbatim.
3. Add frontmatter with `resource` set to the original's repo path (e.g.
   `/ansible/docs/rabbitmq.md`).
4. Rewrite links: doc-to-doc links that now have wiki counterparts become
   bundle-absolute wiki links; links to repo files with no wiki page become
   plain code-span paths (a markdown link would escape the bundle — OKF108).
5. Add a `# Citations` section naming the source doc and the main
   roles/playbooks it describes.
6. Leave the original file unmodified.
7. Add a `## YYYY-MM-DD` entry to `wiki/log.md` (newest-first) noting the
   migration.
8. Run `okf index` and `okf check` per `validating-the-wiki`; finish at 0
   errors, 0 warnings.

## Common Mistakes

- **Deleting or gutting the original.** The original remains the authoritative
  `resource` until a deliberate decision retires it.
- **Leaving links pointing at `ansible/docs/`.** Rewrite them: wiki link if a
  counterpart page exists, plain code-span path otherwise.
- **Migrating listings.** `ansible/docs/index.md` and similar TOC files aren't
  concepts; their role is played by the generated wiki indexes.
- **Skipping the log entry and re-index.** A migration adds a page, so
  `wiki/log.md` gets an entry and `okf index` must run.
