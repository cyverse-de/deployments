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
    root = make_bundle(
        {
            "index.md": ROOT_INDEX,
            "log.md": LOG,
            "sub/page.md": PAGE,
            "stale/page.md": PAGE,
            "stale/index.md": "# stale\n\nwrong content\n",
        }
    )
    assert main(["index", str(root)]) == 0
    assert (
        root / "sub/index.md"
    ).read_text() == "# sub\n\n* [A Page](/sub/page.md) - A test page.\n"
    assert (
        root / "stale/index.md"
    ).read_text() == "# stale\n\n* [A Page](/stale/page.md) - A test page.\n"
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


def test_index_json_outputs(make_bundle, capsys):
    root = make_bundle({"index.md": ROOT_INDEX, "log.md": LOG, "sub/page.md": PAGE})
    assert main(["index", "--check", "--format", "json", str(root)]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["findings"][0]["code"] == "OKF106"
    assert main(["index", "--format", "json", str(root)]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert len(payload["written"]) == 1
    assert payload["written"][0].endswith("sub/index.md")
    assert "error" not in payload


def test_index_partial_write_failure_reports_progress(make_bundle, capsys):
    root = make_bundle(
        {"index.md": ROOT_INDEX, "log.md": LOG, "a/page.md": PAGE, "b/page.md": PAGE}
    )
    (root / "b").chmod(0o555)
    try:
        rc = main(["index", str(root)])
    finally:
        (root / "b").chmod(0o755)
    assert rc == 1
    out, err = capsys.readouterr()
    assert "wrote" in out and "a/index.md" in out
    assert "failed to write" in err and "b/index.md" in err
    assert (root / "a/index.md").is_file()
    assert not (root / "b/index.md").exists()


def test_default_root_discovered_from_repo_root_and_below(
    tmp_path, monkeypatch, capsys
):
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / "wiki").mkdir()
    (repo / "wiki" / "index.md").write_text(ROOT_INDEX)
    (repo / "wiki" / "log.md").write_text(LOG)
    monkeypatch.chdir(repo)
    assert main(["check"]) == 0
    capsys.readouterr()
    deep = repo / "scripts" / "okf"
    deep.mkdir(parents=True)
    monkeypatch.chdir(deep)
    assert main(["check"]) == 0


def test_default_root_missing_stops_at_git_root(tmp_path, monkeypatch, capsys):
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    inner = repo / "somewhere"
    inner.mkdir()
    monkeypatch.chdir(inner)
    assert main(["check"]) == 2
    assert "pass the bundle path explicitly" in capsys.readouterr().err


def test_default_root_without_version_rejected(tmp_path, monkeypatch, capsys):
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / "wiki").mkdir()
    (repo / "wiki" / "index.md").write_text("# W\n")
    monkeypatch.chdir(repo)
    assert main(["check"]) == 2
    assert "okf_version" in capsys.readouterr().err


def test_root_index_yaml_error_is_surfaced(make_bundle, capsys):
    root = make_bundle(
        {"index.md": '---\nokf_version: "0.1\n---\n\n# W\n', "log.md": LOG}
    )
    assert main(["check", str(root)]) == 2
    err = capsys.readouterr().err
    assert "frontmatter" in err and "invalid YAML" in err


def test_root_index_unreadable_is_reported(tmp_path, capsys):
    (tmp_path / "index.md").write_bytes(b"\xff\xfe not utf-8")
    assert main(["check", str(tmp_path)]) == 2
    assert "cannot read" in capsys.readouterr().err
