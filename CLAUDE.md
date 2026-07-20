# deployments

## Wiki upkeep

This repo has an OKF wiki at `wiki/` summarizing its roles, playbooks, and
docs. After changing files under `ansible/`, `kustomize/`, `notes/`, or
`scripts/`, run the `updating-the-wiki` skill check before finishing the task:
find wiki pages that reference the changed files and refresh any that went
stale. Don't wait to be asked.

Wiki edits follow the `writing-wiki-pages` / `migrating-docs-to-wiki` skills
and must end with `okf index` + `okf check` (run via uv from `scripts/okf`)
reporting 0 errors and 0 warnings — see `validating-the-wiki`.
