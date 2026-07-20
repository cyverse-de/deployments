---
name: searching-the-wiki
description: Use when answering questions about how this deployment is set up or operated — consult wiki/ before digging through ansible/ source; e.g. "how is postgres initialized" or "where do the NATS certs come from".
---

# Searching the Wiki

## Overview

`wiki/` is the curated knowledge layer for this repo (OKF v0.1 format). It's
the fastest place to answer "how does X work here" questions: each concept
page has frontmatter (`type`, `title`, `description`, `tags`) and a body, and
its `resource` field plus `# Citations` section point at the authoritative
files in the repo. The wiki summarizes; the cited files are ground truth.

## When to Use

- Answering operational or architectural questions about this deployment
  before grepping ansible/ from scratch.
- NOT for creating or editing pages — see `writing-wiki-pages`.
- If the answer is missing or stale, say so; offer to add it via
  `writing-wiki-pages` or `migrating-docs-to-wiki`.

## Quick Reference

```bash
# Entry point: sections and their indexes
cat wiki/index.md

# Search frontmatter metadata
grep -rl 'tags: \[.*postgres' wiki/
grep -rl 'type: Runbook' wiki/

# Search page content
grep -ril 'pg_hba' wiki/
```

Navigation: start at `wiki/index.md`, follow a section link
(e.g. `/infrastructure/index.md`), pick the page by its one-line description.
Bundle-absolute links like `/infrastructure/nats.md` resolve relative to
`wiki/`, i.e. `wiki/infrastructure/nats.md`.

## Trust Model

- Frontmatter `description` lines in the indexes are reliable summaries — they
  are generated from the pages themselves.
- A page's `timestamp` says when it last had a meaningful change; for anything
  operationally destructive (deletes, prod changes), verify against the file
  named in `resource` / Citations before acting.
- `wiki/log.md` records what changed and when, newest-first.

## Common Mistakes

- **Treating a dead link as an error.** In OKF, a link to a nonexistent page
  marks knowledge that isn't written yet — fall back to the repo source, and
  optionally offer to write the missing page.
- **Trusting the wiki over its sources for risky actions.** The wiki is a
  summary; the `resource` file and the roles/playbooks it cites are
  authoritative.
- **Grepping ansible/ first.** Check the wiki first — if it answers the
  question, you're done; if not, you've lost a few seconds.
