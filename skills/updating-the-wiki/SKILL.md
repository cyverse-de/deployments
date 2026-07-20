---
name: updating-the-wiki
description: Use when finishing any task that changed files under ansible/, kustomize/, notes/, or scripts/ — before ending the task, check whether wiki pages reference the changed files and refresh any that went stale. Fires proactively at the end of ordinary deployment work, not only when the user mentions the wiki.
---

# Updating the Wiki

## Overview

The wiki at `wiki/` summarizes repo files; each page points at its sources via
the `resource` frontmatter field and `# Citations`. When those sources change,
the pages go stale silently. This skill is the end-of-task check that catches
that: after modifying roles, playbooks, docs, or tooling, find the wiki pages
that reference what changed and bring them up to date.

## When to Use

- At the end of **any** task that modified files under `ansible/`,
  `kustomize/`, `notes/`, or `scripts/` — even (especially) when the task had
  nothing to do with the wiki.
- When asked "is the wiki up to date?"
- NOT for making the page edits themselves — see `writing-wiki-pages`.
- NOT for converting a doc into the wiki — see `migrating-docs-to-wiki`.

## The Check

1. List what changed in this task (`git status --porcelain`, or
   `git diff --name-only main...` for whole-branch work).
2. For each changed file, search the wiki for references — most specific path
   first, then the containing role/playbook/doc directory:

```bash
grep -rln 'ansible/roles/nats' wiki/
grep -rln 'ansible/docs/postgresql.md' wiki/
```

   Ignore matches on generic prefixes (`ansible/` alone matches everything).
3. grep only finds *cited* paths — also skim the section `index.md`
   descriptions for pages that cover the changed area topically without citing
   the exact file.
4. For each candidate page: read it and compare against the change.
   - Behavior described by the page changed → update the body and `timestamp`
     per `writing-wiki-pages`.
   - The change introduced a genuinely new concept → offer a new page
     (`writing-wiki-pages`) or migration (`migrating-docs-to-wiki`).
   - Page still accurate → leave it alone.
5. If nothing is affected, say so in one sentence and finish — don't force an
   edit.
6. If any page changed: add a `wiki/log.md` entry and run
   `validating-the-wiki` to zero errors and warnings.

## Common Mistakes

- **Skipping the check because the task "wasn't about the wiki."** That is
  exactly when this skill fires; wiki-focused tasks already use the other
  skills.
- **Updating only the `timestamp`.** The timestamp marks a meaningful change;
  if the body is still accurate, don't touch the page.
- **Treating zero grep hits as proof.** Citations are paths the authors chose
  to cite; a page can cover changed behavior without naming the file. Check
  the indexes too.
- **Ending the task with stale pages "for later."** The whole point is that
  updates happen in the same task as the change. If the user explicitly defers
  the update, tell them exactly which pages are stale so nothing is lost.
