"""Table-driven OKF v0.1 conformance (ERROR) and lint (WARN) rules."""

import re
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import date, datetime

from okf import indexgen
from okf.bundle import Bundle, LinkClass, Page, PageKind, classify_link, iter_body_lines

ERROR = "ERROR"
WARN = "WARN"

_ISO_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
_VERSION_RE = re.compile(r"\d+\.\d+")


@dataclass(frozen=True)
class Finding:
    rel: str
    line: int
    severity: str
    code: str
    message: str


PageFindings = Iterator[tuple[int, str]]
BundleFindings = Iterator[tuple[str, int, str]]
PageCheck = Callable[["Page", "Bundle"], PageFindings]
BundleCheck = Callable[["Bundle"], BundleFindings]


@dataclass(frozen=True)
class Rule:
    code: str
    severity: str
    scope: str  # "concept", "index", "log", "page", or "bundle"
    check: PageCheck | BundleCheck


def _no_frontmatter(page: Page, bundle: Bundle) -> PageFindings:
    if not page.fm.present:
        yield 1, "concept document has no frontmatter block"


def _bad_frontmatter(page: Page, bundle: Bundle) -> PageFindings:
    if page.fm.present and page.fm.error:
        yield 1, page.fm.error


def _bad_type(page: Page, bundle: Bundle) -> PageFindings:
    data = page.fm.data
    if data is None:
        return
    if "type" not in data:
        yield 1, "required frontmatter field 'type' is missing"
    elif not isinstance(data["type"], str):
        yield 1, "required frontmatter field 'type' must be a string"
    elif not data["type"].strip():
        yield 1, "required frontmatter field 'type' is empty"


def _index_frontmatter(page: Page, bundle: Bundle) -> PageFindings:
    if page.kind is PageKind.INDEX:
        if page.fm.present:
            yield 1, "index.md must not contain frontmatter"
        return
    if not page.fm.present:
        return
    if page.fm.error:
        yield 1, f"root index.md frontmatter: {page.fm.error}"
        return
    version = (page.fm.data or {}).get("okf_version")
    if not isinstance(version, str) or not _VERSION_RE.fullmatch(version):
        yield (
            1,
            'root index.md frontmatter must declare okf_version as a string like "0.1"',
        )


def _log_frontmatter(page: Page, bundle: Bundle) -> PageFindings:
    if page.fm.present:
        yield 1, "log.md must not contain frontmatter"


def _log_structure(page: Page, bundle: Bundle) -> PageFindings:
    # Frontmatter presence is already OKF005; skip to avoid cascading noise.
    if page.fm.present:
        return
    seen_title = False
    seen_group = False
    for lineno, heading, line in _log_lines(page):
        if heading is not None:
            if not _ISO_DATE_RE.fullmatch(heading) or not _parse_date(heading):
                yield (
                    lineno,
                    f"log heading '{heading}' is not an ISO 8601 date (YYYY-MM-DD)",
                )
            seen_group = True
        elif line.startswith("# "):
            if seen_title or seen_group:
                yield lineno, "log.md may only have one leading '# ' title"
            seen_title = True
        elif not seen_group:
            yield lineno, "log content must appear under a '## YYYY-MM-DD' heading"


def _log_order(page: Page, bundle: Bundle) -> PageFindings:
    if page.fm.present:
        return
    prev = None
    for lineno, heading, _ in _log_lines(page):
        if heading is None:
            continue
        current = _parse_date(heading) if _ISO_DATE_RE.fullmatch(heading) else None
        if current is None:
            continue
        if prev is not None and current > prev:
            yield (
                lineno,
                f"log dates must be newest-first: {heading} appears after {prev}",
            )
        prev = current


def _log_lines(page: Page) -> Iterator[tuple[int, str | None, str]]:
    """Yield (line number, date heading or None, stripped line) for non-blank log lines."""
    for lineno, raw in iter_body_lines(page.text):
        line = raw.strip()
        if not line:
            continue
        heading = line[3:].strip() if line.startswith("## ") else None
        yield lineno, heading, line


def _parse_date(text: str) -> date | None:
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def _unreadable(page: Page, bundle: Bundle) -> PageFindings:
    if page.read_error:
        yield 1, f"file could not be read: {page.read_error}"


def _dead_links(page: Page, bundle: Bundle) -> PageFindings:
    for link in page.links:
        resolved = classify_link(page.rel, link.target)
        if resolved.cls not in (LinkClass.INTERNAL, LinkClass.UPWARD):
            continue
        if not (bundle.root / resolved.rel).exists():
            yield link.line, f"dead link: {link.target} does not exist in the bundle"


def _escaping_links(page: Page, bundle: Bundle) -> PageFindings:
    for link in page.links:
        if classify_link(page.rel, link.target).cls is LinkClass.ESCAPES:
            yield (
                link.line,
                f"link {link.target} escapes the bundle root; use a plain `path` "
                "reference or the resource field instead",
            )


def _upward_links(page: Page, bundle: Bundle) -> PageFindings:
    for link in page.links:
        resolved = classify_link(page.rel, link.target)
        if resolved.cls is LinkClass.UPWARD:
            yield (
                link.line,
                f"upward-relative link {link.target}; prefer bundle-absolute /{resolved.rel}",
            )


def _missing_title(page: Page, bundle: Bundle) -> PageFindings:
    if page.fm.data is not None and "title" not in page.fm.data:
        yield 1, "recommended frontmatter field 'title' is missing"


def _missing_description(page: Page, bundle: Bundle) -> PageFindings:
    if page.fm.data is not None and "description" not in page.fm.data:
        yield 1, "recommended frontmatter field 'description' is missing"


def _bad_timestamp(page: Page, bundle: Bundle) -> PageFindings:
    data = page.fm.data
    if data is None:
        return
    if "timestamp" not in data:
        yield 1, "recommended frontmatter field 'timestamp' is missing"
        return
    value = data["timestamp"]
    if isinstance(value, datetime | date):
        return
    if isinstance(value, str):
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
            return
        except ValueError:
            pass
    yield 1, f"'timestamp' is not an ISO 8601 datetime: {value!r}"


def _bad_tags(page: Page, bundle: Bundle) -> PageFindings:
    data = page.fm.data
    if data is None or "tags" not in data:
        return
    tags = data["tags"]
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        yield 1, "'tags' must be a list of strings"


def _symlinked_dirs(bundle: Bundle) -> BundleFindings:
    for path in sorted(bundle.root.rglob("*")):
        if not path.is_dir() or not path.is_symlink():
            continue
        parts = path.relative_to(bundle.root).parts
        if any(part.startswith(".") for part in parts):
            continue
        rel = path.relative_to(bundle.root).as_posix()
        yield (
            rel,
            1,
            "symlinked directory is ignored by validation and indexing; use a real directory",
        )


def _index_drift(bundle: Bundle) -> BundleFindings:
    for entry in indexgen.drift(bundle):
        if entry.status == "missing":
            yield entry.rel, 1, "index.md is missing; run 'okf index' to generate it"
        else:
            yield entry.rel, 1, "index.md is stale; run 'okf index' to regenerate it"


RULES = [
    Rule("OKF001", ERROR, "concept", _no_frontmatter),
    Rule("OKF002", ERROR, "concept", _bad_frontmatter),
    Rule("OKF003", ERROR, "concept", _bad_type),
    Rule("OKF004", ERROR, "index", _index_frontmatter),
    Rule("OKF005", ERROR, "log", _log_frontmatter),
    Rule("OKF006", ERROR, "log", _log_structure),
    Rule("OKF007", ERROR, "page", _unreadable),
    Rule("OKF101", WARN, "page", _dead_links),
    Rule("OKF102", WARN, "concept", _missing_title),
    Rule("OKF103", WARN, "concept", _missing_description),
    Rule("OKF104", WARN, "concept", _bad_timestamp),
    Rule("OKF105", WARN, "concept", _bad_tags),
    Rule("OKF106", WARN, "bundle", _index_drift),
    Rule("OKF107", WARN, "log", _log_order),
    Rule("OKF108", WARN, "page", _escaping_links),
    Rule("OKF109", WARN, "page", _upward_links),
    Rule("OKF110", WARN, "bundle", _symlinked_dirs),
]

_SCOPE_KINDS = {
    "concept": {PageKind.CONCEPT},
    "index": {PageKind.INDEX, PageKind.ROOT_INDEX},
    "log": {PageKind.LOG},
    "page": set(PageKind),
}


def run_checks(bundle: Bundle) -> list[Finding]:
    """Run every rule against the bundle, returning findings in deterministic order."""
    findings = []
    for rule in RULES:
        if rule.scope == "bundle":
            for rel, line, message in rule.check(bundle):
                findings.append(Finding(rel, line, rule.severity, rule.code, message))
            continue
        kinds = _SCOPE_KINDS[rule.scope]
        for page in bundle.pages:
            if page.kind not in kinds:
                continue
            # An unreadable file gets only OKF007, not cascading noise from its empty text.
            if page.read_error and rule.code != "OKF007":
                continue
            for line, message in rule.check(page, bundle):
                findings.append(
                    Finding(page.rel, line, rule.severity, rule.code, message)
                )
    findings.sort(key=lambda f: (f.rel, f.line, f.code))
    return findings
