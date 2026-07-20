"""Generation of expected index.md content for bundle subdirectories."""

import posixpath
from dataclasses import dataclass

from okf.bundle import Bundle, Page, PageKind


@dataclass(frozen=True)
class IndexDrift:
    rel: str
    status: str  # "missing" or "stale"
    expected: str


def expected_indexes(bundle: Bundle) -> dict[str, str]:
    """Expected index.md content for every directory below the bundle root."""
    return {
        posixpath.join(rel, "index.md"): _render(bundle, rel)
        for rel in _subdirectories(bundle.root)
    }


def drift(bundle: Bundle) -> list[IndexDrift]:
    """Subdirectory index.md files that are missing or differ from generated content."""
    on_disk = {page.rel: page.text for page in bundle.pages}
    result = []
    for rel, expected in sorted(expected_indexes(bundle).items()):
        if rel not in on_disk:
            result.append(IndexDrift(rel, "missing", expected))
        elif on_disk[rel] != expected:
            result.append(IndexDrift(rel, "stale", expected))
    return result


def _subdirectories(root):
    for path in sorted(root.rglob("*")):
        if not path.is_dir():
            continue
        parts = path.relative_to(root).parts
        if any(part.startswith(".") for part in parts):
            continue
        yield path.relative_to(root).as_posix()


def _render(bundle: Bundle, dir_rel: str) -> str:
    entries = []
    for sub in _subdirectories(bundle.root):
        if posixpath.dirname(sub) == dir_rel:
            name = posixpath.basename(sub)
            entries.append(f"* [{name}/](/{sub}/index.md)")
    for page in bundle.pages:
        if page.kind is PageKind.CONCEPT and posixpath.dirname(page.rel) == dir_rel:
            entries.append(_entry(page))
    heading = f"# {posixpath.basename(dir_rel)}"
    return "\n".join([heading, "", *entries]) + "\n"


def _entry(page: Page) -> str:
    data = page.fm.data or {}
    title = data.get("title")
    if not isinstance(title, str) or not title.strip():
        title = page.rel.removesuffix(".md")
    description = data.get("description")
    entry = f"* [{title}](/{page.rel})"
    if isinstance(description, str) and description.strip():
        entry += f" - {description.strip()}"
    return entry
