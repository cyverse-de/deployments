"""Command-line interface: okf check and okf index."""

import argparse
import json
import os
import sys
from pathlib import Path

from okf import frontmatter, indexgen, rules
from okf.bundle import Bundle, load_bundle


class UsageError(Exception):
    """Environment or usage problem; reported on stderr with exit code 2."""


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        root = _resolve_bundle_root(args.path)
        bundle = load_bundle(root)
        if args.command == "check":
            return _run_check(bundle, args)
        return _run_index(bundle, args)
    except UsageError as exc:
        print(f"okf: {exc}", file=sys.stderr)
        return 2


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="okf", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser(
        "check", help="validate the bundle (conformance + lint)"
    )
    _add_common(check)
    check.add_argument("--strict", action="store_true", help="exit 1 on warnings too")

    index = subparsers.add_parser(
        "index", help="generate/update subdirectory index.md files"
    )
    _add_common(index)
    index.add_argument(
        "--check", action="store_true", help="report drift without writing"
    )

    return parser


def _add_common(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument(
        "path", nargs="?", help="bundle root (default: wiki/ under the repo root)"
    )
    subparser.add_argument("--format", choices=["text", "json"], default="text")


def _resolve_bundle_root(path_arg: str | None) -> Path:
    if path_arg:
        root = Path(path_arg)
        if not root.is_dir():
            raise UsageError(f"{path_arg} is not a directory")
    else:
        root = _find_default_root()
    index = root / "index.md"
    if not index.is_file():
        raise UsageError(f"{root} is not an OKF bundle root: no index.md")
    try:
        text = index.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        raise UsageError(f"cannot read {index}: {exc}") from None
    fm = frontmatter.parse(text)
    if fm.present and fm.error:
        raise UsageError(f"{index} frontmatter: {fm.error}")
    if not fm.present or fm.data is None or "okf_version" not in fm.data:
        raise UsageError(
            f"{root} is not an OKF bundle root: index.md does not declare okf_version"
        )
    return root


def _find_default_root() -> Path:
    current = Path.cwd()
    while True:
        candidate = current / "wiki"
        if (candidate / "index.md").is_file():
            return candidate
        if (current / ".git").exists() or current.parent == current:
            raise UsageError(
                "no wiki/ bundle found between the current directory and the repo root; "
                "pass the bundle path explicitly"
            )
        current = current.parent


def _run_check(bundle: Bundle, args: argparse.Namespace) -> int:
    findings = rules.run_checks(bundle)
    errors = sum(1 for f in findings if f.severity == rules.ERROR)
    warnings = len(findings) - errors
    summary = {"errors": errors, "warnings": warnings, "files": len(bundle.pages)}
    if args.format == "json":
        print(
            json.dumps(
                {
                    "findings": [_finding_json(bundle, f) for f in findings],
                    "summary": summary,
                }
            )
        )
    else:
        for f in findings:
            print(_finding_text(bundle, f))
        print(
            f"okf check: {_count(errors, 'error')}, {_count(warnings, 'warning')} "
            f"in {_count(len(bundle.pages), 'file')}"
        )
    if errors or (args.strict and warnings):
        return 1
    return 0


def _run_index(bundle: Bundle, args: argparse.Namespace) -> int:
    drift = indexgen.drift(bundle)
    if args.check:
        findings = [
            rules.Finding(d.rel, 1, rules.WARN, "OKF106", f"index.md is {d.status}")
            for d in drift
        ]
        summary = {"errors": 0, "warnings": len(findings), "files": len(bundle.pages)}
        if args.format == "json":
            print(
                json.dumps(
                    {
                        "findings": [_finding_json(bundle, f) for f in findings],
                        "summary": summary,
                    }
                )
            )
        else:
            for f in findings:
                print(_finding_text(bundle, f))
            print(
                f"okf index --check: {_count(len(findings), 'index file')} out of date"
            )
        return 1 if drift else 0

    written = []
    failure = None
    for d in drift:
        display = _display_path(bundle, d.rel)
        try:
            (bundle.root / d.rel).write_text(d.expected, encoding="utf-8")
        except OSError as exc:
            failure = f"failed to write {display}: {exc}"
            break
        written.append(display)
        # Report each write as it lands so a later failure can't hide it.
        if args.format != "json":
            print(f"wrote {display}")
    if args.format == "json":
        payload: dict = {"written": written}
        if failure:
            payload["error"] = failure
        print(json.dumps(payload))
    elif failure:
        print(f"okf index: {failure}", file=sys.stderr)
        print(
            f"okf index: wrote {len(written)} of {_count(len(drift), 'index file')} needed"
        )
    else:
        print(f"okf index: {_count(len(written), 'index file')} written")
    return 1 if failure else 0


def _display_path(bundle: Bundle, rel: str) -> str:
    return os.path.relpath(bundle.root / rel)


def _finding_text(bundle: Bundle, f: rules.Finding) -> str:
    return f"{_display_path(bundle, f.rel)}:{f.line}: {f.severity} {f.code} {f.message}"


def _finding_json(bundle: Bundle, f: rules.Finding) -> dict:
    return {
        "file": _display_path(bundle, f.rel),
        "line": f.line,
        "severity": f.severity,
        "code": f.code,
        "message": f.message,
    }


def _count(n: int, noun: str) -> str:
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"
