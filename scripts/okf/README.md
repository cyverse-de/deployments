# okf

Validates and indexes the [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
(v0.1) wiki bundle at the top of this repo (`wiki/`). Managed with
[uv](https://docs.astral.sh/uv/); no install step needed.

```bash
cd scripts/okf

# Validate: conformance ERRORs + lint WARNs (dead links, missing fields, index drift)
uv run okf check ../../wiki

# Regenerate subdirectory index.md files from concept frontmatter
uv run okf index ../../wiki

# Report index drift without writing
uv run okf index --check ../../wiki
```

Output is line-oriented (`file:line: SEVERITY CODE message`); pass
`--format json` for machine-readable output. Exit codes: `0` clean (warnings
allowed), `1` errors found (or warnings with `--strict`, or drift with
`index --check`), `2` usage/environment problem.

Rule codes: `OKF001`–`OKF007` are errors (OKF frontmatter/reserved-file
conformance, plus unreadable files); `OKF101`–`OKF110` are lint warnings (dead
links, missing recommended fields, index drift, log ordering, link style,
symlinked directories). See
`src/okf/rules.py` for the full table, and the `validating-the-wiki` skill for
how to interpret and fix each code.

Development:

```bash
uv run pytest
uv run ruff check .
uv run ruff format .
```
