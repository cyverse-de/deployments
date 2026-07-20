from conftest import LOG, PAGE, ROOT_INDEX, page_with

from okf import indexgen
from okf.bundle import load_bundle


def test_expected_index_lists_subdirs_then_pages(make_bundle):
    root = make_bundle(
        {
            "index.md": ROOT_INDEX,
            "log.md": LOG,
            "sub/page.md": PAGE,
            "sub/inner/x.md": PAGE,
        }
    )
    expected = indexgen.expected_indexes(load_bundle(root))
    assert expected["sub/index.md"] == (
        "# sub\n\n* [inner/](/sub/inner/index.md)\n* [A Page](/sub/page.md) - A test page.\n"
    )
    assert (
        expected["sub/inner/index.md"]
        == "# inner\n\n* [A Page](/sub/inner/x.md) - A test page.\n"
    )


def test_entry_falls_back_to_concept_id(make_bundle):
    root = make_bundle(
        {
            "index.md": ROOT_INDEX,
            "log.md": LOG,
            "sub/page.md": page_with(["type: Note"]),
        }
    )
    expected = indexgen.expected_indexes(load_bundle(root))
    assert expected["sub/index.md"] == "# sub\n\n* [sub/page](/sub/page.md)\n"


def test_drift_statuses(make_bundle):
    root = make_bundle(
        {
            "index.md": ROOT_INDEX,
            "log.md": LOG,
            "missing/page.md": PAGE,
            "stale/page.md": PAGE,
            "stale/index.md": "# stale\n\nwrong\n",
            "clean/page.md": PAGE,
            "clean/index.md": "# clean\n\n* [A Page](/clean/page.md) - A test page.\n",
        }
    )
    drift = indexgen.drift(load_bundle(root))
    assert [(d.rel, d.status) for d in drift] == [
        ("missing/index.md", "missing"),
        ("stale/index.md", "stale"),
    ]
