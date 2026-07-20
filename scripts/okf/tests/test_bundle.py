import pytest

from okf.bundle import _links

# Pins the link extractor's known behavior, including its deliberate blind
# spots: space/angle-bracket/empty targets are invisible to all link rules,
# and an unescaped paren truncates the target.
CASES = [
    ("plain", "[a](/x.md)", ["/x.md"]),
    ("two_links_one_line", "[a](/x.md) [b](/y.md)", ["/x.md", "/y.md"]),
    ("title_stripped", '[a](/x.md "Title")', ["/x.md"]),
    ("image_extracted", "![alt](/pic.png)", ["/pic.png"]),
    ("space_in_target_not_extracted", "[a](my file.md)", []),
    ("angle_bracket_form_unwrapped", "[a](<file.md>)", ["file.md"]),
    ("angle_bracket_with_space_not_extracted", "[a](<my file.md>)", []),
    ("empty_target_not_extracted", "[a]()", []),
    ("paren_in_target_truncates", "[a](foo(1).md)", ["foo(1"]),
]


@pytest.mark.parametrize("name,line,expected", CASES, ids=[c[0] for c in CASES])
def test_link_extraction(name, line, expected):
    assert [link.target for link in _links(line, 1)] == expected
