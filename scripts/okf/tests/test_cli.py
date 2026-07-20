import json

from conftest import LOG, PAGE, ROOT_INDEX, page_with

from okf.cli import main

CLEAN = {
    "index.md": ROOT_INDEX,
    "log.md": LOG,
    "sub/page.md": PAGE,
    "sub/index.md": "# sub\n\n* [A Page](/sub/page.md) - A test page.\n",
}


def test_check_clean(make_bundle, capsys):
    root = make_bundle(CLEAN)
    assert main(["check", str(root)]) == 0
    out = capsys.readouterr().out
    assert "0 errors, 0 warnings in 4 files" in out


def test_check_error_exit_code(make_bundle, capsys):
    root = make_bundle({**CLEAN, "bad.md": "no frontmatter\n"})
    assert main(["check", str(root)]) == 1
    out = capsys.readouterr().out
    assert "ERROR OKF001" in out
    assert "1 error, 0 warnings" in out


def test_check_warnings_pass_unless_strict(make_bundle, capsys):
    files = {**CLEAN, "warn.md": page_with(["type: Note"])}
    root = make_bundle(files)
    assert main(["check", str(root)]) == 0
    capsys.readouterr()
    assert main(["check", "--strict", str(root)]) == 1


def test_check_json_shape(make_bundle, capsys):
    root = make_bundle({**CLEAN, "bad.md": "no frontmatter\n"})
    assert main(["check", "--format", "json", str(root)]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["summary"] == {"errors": 1, "warnings": 0, "files": 5}
    finding = payload["findings"][0]
    assert set(finding) == {"file", "line", "severity", "code", "message"}
    assert finding["code"] == "OKF001"


def test_check_findings_are_sorted(make_bundle, capsys):
    root = make_bundle(
        {
            **CLEAN,
            "a.md": "no frontmatter\n",
            "b.md": page_with(["type: Note"], "[gone](/missing.md)\n"),
        }
    )
    main(["check", "--format", "json", str(root)])
    payload = json.loads(capsys.readouterr().out)
    keys = [(f["file"], f["line"], f["code"]) for f in payload["findings"]]
    assert keys == sorted(keys)


def test_not_a_directory(tmp_path, capsys):
    assert main(["check", str(tmp_path / "nope")]) == 2
    assert "not a directory" in capsys.readouterr().err


def test_not_a_bundle_root(tmp_path, capsys):
    assert main(["check", str(tmp_path)]) == 2
    assert "no index.md" in capsys.readouterr().err


def test_root_index_without_version(make_bundle, capsys):
    root = make_bundle({"index.md": "# W\n", "log.md": LOG})
    assert main(["check", str(root)]) == 2
    assert "okf_version" in capsys.readouterr().err


def test_index_writes_missing_and_stale(make_bundle, capsys):
    root = make_bundle({"index.md": ROOT_INDEX, "log.md": LOG, "sub/page.md": PAGE})
    assert main(["index", str(root)]) == 0
    assert (
        root / "sub/index.md"
    ).read_text() == "# sub\n\n* [A Page](/sub/page.md) - A test page.\n"
    capsys.readouterr()
    assert main(["index", "--check", str(root)]) == 0
    capsys.readouterr()
    assert main(["check", str(root)]) == 0


def test_index_never_touches_root_index(make_bundle):
    root = make_bundle({"index.md": ROOT_INDEX, "log.md": LOG, "page.md": PAGE})
    main(["index", str(root)])
    assert (root / "index.md").read_text() == ROOT_INDEX


def test_index_check_reports_drift(make_bundle, capsys):
    root = make_bundle({"index.md": ROOT_INDEX, "log.md": LOG, "sub/page.md": PAGE})
    assert main(["index", "--check", str(root)]) == 1
    out = capsys.readouterr().out
    assert "OKF106" in out
