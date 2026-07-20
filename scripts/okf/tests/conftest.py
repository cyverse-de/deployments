import pytest

ROOT_INDEX = """---
okf_version: "0.1"
---

# Test Wiki
"""

LOG = """# Log

## 2026-07-20

* **Initialization**: Created the bundle.
"""

PAGE = """---
type: Note
title: A Page
description: A test page.
tags: [test]
timestamp: 2026-07-20T00:00:00Z
---

Body text.
"""


def page_with(frontmatter_lines: list[str], body: str = "Body text.\n") -> str:
    return "---\n" + "\n".join(frontmatter_lines) + "\n---\n\n" + body


@pytest.fixture
def make_bundle(tmp_path):
    def _make(files: dict[str, str]):
        for rel, content in files.items():
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return tmp_path

    return _make
