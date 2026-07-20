import pytest

from okf import frontmatter

CASES = [
    ("no_block", "Just a body.\n", False, None, None),
    ("not_at_top", "\n---\ntype: X\n---\n", False, None, None),
    (
        "valid",
        '---\ntype: Note\ntitle: "T"\n---\n\nBody.\n',
        True,
        {"type": "Note", "title": "T"},
        None,
    ),
    (
        "empty_block",
        "---\n---\nBody.\n",
        True,
        None,
        "frontmatter is empty or not a YAML mapping",
    ),
    (
        "non_mapping",
        "---\n- a\n- b\n---\n",
        True,
        None,
        "frontmatter is empty or not a YAML mapping",
    ),
    ("invalid_yaml", "---\ntype: [unclosed\n---\n", True, None, "invalid YAML"),
    (
        "unterminated",
        "---\ntype: Note\n\nBody.\n",
        True,
        None,
        "unterminated frontmatter block",
    ),
]


@pytest.mark.parametrize(
    "name,text,present,data,error", CASES, ids=[c[0] for c in CASES]
)
def test_parse(name, text, present, data, error):
    fm = frontmatter.parse(text)
    assert fm.present is present
    assert fm.data == data
    if error is None:
        assert fm.error is None
    else:
        assert fm.error is not None and fm.error.startswith(error)


def test_body_start_line():
    fm = frontmatter.parse("---\ntype: Note\n---\nBody on line 4.\n")
    assert fm.body_start == 4
