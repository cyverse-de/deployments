import pytest
from conftest import LOG, PAGE, ROOT_INDEX, page_with

from okf.bundle import load_bundle
from okf.rules import run_checks

FM = [
    "type: Note",
    "title: A Page",
    "description: A test page.",
    "tags: [test]",
    "timestamp: 2026-07-20T00:00:00Z",
]

SUB_INDEX = "# sub\n\n* [A Page](/sub/page.md) - A test page.\n"

LOG_BAD_DATE = "# Log\n\n## July 20\n\n* x\n"
LOG_STRAY_CONTENT = "# Log\n\nStray line.\n\n## 2026-07-20\n\n* x\n"
LOG_OUT_OF_ORDER = "# Log\n\n## 2026-07-18\n\n* x\n\n## 2026-07-20\n\n* y\n"


def base(**files: str) -> dict[str, str]:
    return {"index.md": ROOT_INDEX, "log.md": LOG, **files}


CASES = [
    ("clean_root_only", base(**{"page.md": PAGE}), []),
    ("no_frontmatter", base(**{"page.md": "Just text.\n"}), ["OKF001"]),
    ("invalid_yaml", base(**{"page.md": page_with(["type: [unclosed"])}), ["OKF002"]),
    ("missing_type", base(**{"page.md": page_with(FM[1:])}), ["OKF003"]),
    ("empty_type", base(**{"page.md": page_with(['type: ""', *FM[1:]])}), ["OKF003"]),
    (
        "non_string_type",
        base(**{"page.md": page_with(["type: 3", *FM[1:]])}),
        ["OKF003"],
    ),
    (
        "subdir_index_frontmatter",
        base(**{"sub/index.md": "---\ntype: X\n---\n\n# sub\n", "sub/page.md": PAGE}),
        ["OKF004", "OKF106"],
    ),
    (
        "root_unquoted_okf_version",
        {
            "index.md": "---\nokf_version: 0.1\n---\n\n# W\n",
            "log.md": LOG,
            "page.md": PAGE,
        },
        ["OKF004"],
    ),
    ("log_frontmatter", base(**{"log.md": "---\na: b\n---\n\n# Log\n"}), ["OKF005"]),
    ("log_bad_date", base(**{"log.md": LOG_BAD_DATE, "page.md": PAGE}), ["OKF006"]),
    (
        "log_stray_content",
        base(**{"log.md": LOG_STRAY_CONTENT, "page.md": PAGE}),
        ["OKF006"],
    ),
    (
        "log_out_of_order",
        base(**{"log.md": LOG_OUT_OF_ORDER, "page.md": PAGE}),
        ["OKF107"],
    ),
    (
        "dead_link",
        base(**{"page.md": page_with(FM, "[gone](/missing.md)\n")}),
        ["OKF101"],
    ),
    (
        "link_in_fence_ignored",
        base(**{"page.md": page_with(FM, "```\n[gone](/missing.md)\n```\n")}),
        [],
    ),
    (
        "anchor_and_external_ignored",
        base(**{"page.md": page_with(FM, "[a](#x) [b](https://example.org/x.md)\n")}),
        [],
    ),
    ("missing_title", base(**{"page.md": page_with([FM[0], *FM[2:]])}), ["OKF102"]),
    (
        "missing_description",
        base(**{"page.md": page_with([*FM[:2], *FM[3:]])}),
        ["OKF103"],
    ),
    ("missing_timestamp", base(**{"page.md": page_with(FM[:4])}), ["OKF104"]),
    (
        "unparseable_timestamp",
        base(**{"page.md": page_with([*FM[:4], "timestamp: not-a-date"])}),
        ["OKF104"],
    ),
    (
        "bad_tags",
        base(**{"page.md": page_with([*FM[:3], "tags: solo", FM[4]])}),
        ["OKF105"],
    ),
    ("missing_subdir_index", base(**{"sub/page.md": PAGE}), ["OKF106"]),
    (
        "stale_subdir_index",
        base(
            **{"sub/page.md": PAGE, "sub/index.md": "# sub\n\n* [Old](/sub/old.md)\n"}
        ),
        ["OKF101", "OKF106"],
    ),
    ("clean_subdir", base(**{"sub/page.md": PAGE, "sub/index.md": SUB_INDEX}), []),
    (
        "escaping_link",
        base(**{"page.md": page_with(FM, "[out](../outside.md)\n")}),
        ["OKF108"],
    ),
    (
        "upward_link_in_bundle",
        base(
            **{
                "other.md": PAGE,
                "sub/page.md": page_with(FM, "[up](../other.md)\n"),
                "sub/index.md": SUB_INDEX,
            }
        ),
        ["OKF109"],
    ),
]


@pytest.mark.parametrize("name,files,expected", CASES, ids=[c[0] for c in CASES])
def test_rules(name, files, expected, make_bundle):
    root = make_bundle(files)
    codes = [finding.code for finding in run_checks(load_bundle(root))]
    assert sorted(codes) == sorted(expected)


def test_finding_locations(make_bundle):
    files = base(**{"page.md": page_with(FM, "line one\n\n[gone](/missing.md)\n")})
    root = make_bundle(files)
    findings = run_checks(load_bundle(root))
    assert len(findings) == 1
    assert findings[0].rel == "page.md"
    assert findings[0].line == 11
    assert findings[0].severity == "WARN"
