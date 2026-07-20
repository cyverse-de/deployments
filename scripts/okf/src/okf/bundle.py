"""Loading an OKF bundle from disk and classifying its files and links."""

import posixpath
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from okf import frontmatter


class PageKind(Enum):
    ROOT_INDEX = "root-index"
    INDEX = "index"
    LOG = "log"
    CONCEPT = "concept"


class LinkClass(Enum):
    EXTERNAL = "external"
    ANCHOR = "anchor"
    ESCAPES = "escapes"
    UPWARD = "upward"
    INTERNAL = "internal"


@dataclass(frozen=True)
class Link:
    line: int
    target: str


@dataclass(frozen=True)
class ResolvedLink:
    cls: LinkClass
    rel: str | None = None


@dataclass(frozen=True)
class Page:
    rel: str
    kind: PageKind
    text: str
    fm: frontmatter.Frontmatter
    links: list[Link]


@dataclass(frozen=True)
class Bundle:
    root: Path
    pages: list[Page]


_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def load_bundle(root: Path) -> Bundle:
    """Load every markdown file under root, skipping hidden directories."""
    pages = []
    for path in sorted(root.rglob("*.md")):
        parts = path.relative_to(root).parts
        if any(part.startswith(".") for part in parts):
            continue
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        fm = frontmatter.parse(text)
        pages.append(
            Page(
                rel=rel,
                kind=_classify(rel),
                text=text,
                fm=fm,
                links=_links(text, fm.body_start),
            )
        )
    return Bundle(root=root, pages=pages)


def _classify(rel: str) -> PageKind:
    name = posixpath.basename(rel)
    if name == "index.md":
        return PageKind.ROOT_INDEX if rel == "index.md" else PageKind.INDEX
    if name == "log.md":
        return PageKind.LOG
    return PageKind.CONCEPT


def _links(text: str, body_start: int) -> list[Link]:
    """Extract inline markdown link targets with line numbers, skipping fenced code."""
    links = []
    in_fence = False
    for lineno, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or lineno < body_start:
            continue
        for match in _LINK_RE.finditer(line):
            links.append(Link(line=lineno, target=match.group(1)))
    return links


def classify_link(page_rel: str, target: str) -> ResolvedLink:
    """Resolve a link target relative to the bundle root and classify it."""
    path = target.split("#", 1)[0]
    if not path:
        return ResolvedLink(LinkClass.ANCHOR)
    if _SCHEME_RE.match(path) or path.startswith("//"):
        return ResolvedLink(LinkClass.EXTERNAL)
    if path.startswith("/"):
        rel = posixpath.normpath(path.lstrip("/"))
        upward = False
    else:
        rel = posixpath.normpath(posixpath.join(posixpath.dirname(page_rel), path))
        upward = path.startswith("../")
    if rel == ".." or rel.startswith("../"):
        return ResolvedLink(LinkClass.ESCAPES)
    if rel == ".":
        rel = ""
    return ResolvedLink(LinkClass.UPWARD if upward else LinkClass.INTERNAL, rel)
