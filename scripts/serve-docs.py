#!/usr/bin/env python3
"""Serve the deployments documentation as HTML in your browser.

Usage:
    python3 scripts/serve-docs.py [--port PORT] [--root ROOT]

Defaults to port 7474 and the repo root inferred from this script's location.
Open http://localhost:7474 after starting.
"""

import argparse
import http.server
import os
import pathlib
import re
import socketserver
import urllib.parse

try:
    import markdown
    import markdown.extensions.toc
    import markdown.extensions.tables
    import markdown.extensions.fenced_code
except ImportError:
    raise SystemExit(
        "The 'markdown' package is required.  Install it with:\n"
        "    pip install markdown"
    )

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent          # deployments/

DOC_DIRS = [
    ("docs",         "Docs"),
    ("ansible/docs", "Ansible Docs"),
    ("ansible",      "Ansible"),
    ("kustomize",    "Kustomize"),
    ("skills",       "Skills"),
    ("notes",        "Notes"),
]

# ---------------------------------------------------------------------------
# HTML chrome
# ---------------------------------------------------------------------------

PAGE_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  *, *::before, *::after {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    font-size: 15px;
    background: #f6f8fa;
    color: #24292f;
    display: flex;
    min-height: 100vh;
  }}
  nav {{
    width: 260px;
    min-width: 200px;
    background: #fff;
    border-right: 1px solid #d0d7de;
    padding: 1rem 0;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
    flex-shrink: 0;
  }}
  nav h2 {{
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #57606a;
    padding: 0.5rem 1rem 0.25rem;
    margin: 0.75rem 0 0;
  }}
  nav h2:first-child {{ margin-top: 0; }}
  nav a {{
    display: block;
    padding: 0.3rem 1rem;
    color: #0969da;
    text-decoration: none;
    font-size: 0.88rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }}
  nav a:hover {{ background: #f6f8fa; }}
  main {{
    flex: 1;
    padding: 2rem 2.5rem;
    max-width: 900px;
  }}
  article {{
    background: #fff;
    border: 1px solid #d0d7de;
    border-radius: 6px;
    padding: 2rem 2.5rem;
  }}
  h1, h2, h3, h4 {{ margin-top: 1.5em; }}
  pre {{
    background: #f6f8fa;
    border: 1px solid #d0d7de;
    border-radius: 6px;
    padding: 1rem;
    overflow-x: auto;
  }}
  code {{ font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.88em; }}
  :not(pre) > code {{ background: #f6f8fa; padding: .15em .3em; border-radius: 4px; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1em 0; }}
  th, td {{ border: 1px solid #d0d7de; padding: .5rem .75rem; text-align: left; }}
  th {{ background: #f6f8fa; }}
  a {{ color: #0969da; }}
  hr {{ border: none; border-top: 1px solid #d0d7de; }}
  .toc {{ background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 6px;
          padding: .75rem 1.25rem; margin-bottom: 2rem; }}
  .toc ul {{ margin: 0; padding-left: 1.5rem; }}
</style>
</head>
<body>
{nav}
<main>
  <article>
    {body}
  </article>
</main>
</body>
</html>
"""

INDEX_ITEM = '<li><a href="{href}">{label}</a></li>'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def collect_markdown_files(root: pathlib.Path) -> dict[str, list[tuple[str, pathlib.Path]]]:
    """Return an ordered dict: section label -> [(display name, path), ...]"""
    sections: dict[str, list[tuple[str, pathlib.Path]]] = {}
    seen: set[pathlib.Path] = set()

    for rel, label in DOC_DIRS:
        d = root / rel
        if not d.is_dir():
            continue
        files = []
        # Direct markdown files first (non-recursive for top-level dirs)
        for f in sorted(d.iterdir()):
            if f.suffix.lower() == ".md" and f not in seen:
                files.append((f.stem.replace("-", " ").replace("_", " ").title(), f))
                seen.add(f)
        # Then one level deep (subdirs)
        for sub in sorted(d.iterdir()):
            if sub.is_dir():
                for f in sorted(sub.glob("*.md")):
                    if f not in seen:
                        name = f"{sub.name}/{f.stem}".replace("-", " ").replace("_", " ")
                        files.append((name.title(), f))
                        seen.add(f)
        if files:
            sections[label] = files

    return sections


def render_markdown(path: pathlib.Path) -> str:
    text = path.read_text(encoding="utf-8")
    md = markdown.Markdown(
        extensions=[
            "toc",
            "tables",
            "fenced_code",
            "footnotes",
            "attr_list",
            "def_list",
            "md_in_html",
        ],
        extension_configs={
            "toc": {"title": "Contents", "toc_depth": 3, "anchorlink": True}
        },
    )
    body = md.convert(text)
    toc = md.toc  # type: ignore[attr-defined]
    if toc and toc.strip() != "<div class=\"toc\">\n<ul></ul>\n</div>":
        toc_html = f'<div class="toc">{toc}</div>'
    else:
        toc_html = ""
    return toc_html + body


def build_nav(sections: dict[str, list[tuple[str, pathlib.Path]]], root: pathlib.Path) -> str:
    parts = ["<nav>"]
    for section, files in sections.items():
        parts.append(f"<h2>{section}</h2>")
        for display, fpath in files:
            rel = fpath.relative_to(root).as_posix()
            href = "/doc/" + urllib.parse.quote(rel)
            parts.append(f'<a href="{href}" title="{rel}">{display}</a>')
    parts.append("</nav>")
    return "\n".join(parts)


def build_index(sections: dict[str, list[tuple[str, pathlib.Path]]], root: pathlib.Path) -> str:
    items: list[str] = []
    for section, files in sections.items():
        items.append(f"<h2>{section}</h2><ul>")
        for display, fpath in files:
            rel = fpath.relative_to(root).as_posix()
            href = "/doc/" + urllib.parse.quote(rel)
            items.append(f'<li><a href="{href}">{display}</a> <small style="color:#57606a">({rel})</small></li>')
        items.append("</ul>")
    body = "<h1>Deployments Documentation</h1>\n" + "\n".join(items)
    return body


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class DocsHandler(http.server.BaseHTTPRequestHandler):
    repo_root: pathlib.Path
    sections: dict[str, list[tuple[str, pathlib.Path]]]
    nav_html: str

    def log_message(self, fmt, *args):  # quieter logging
        print(f"  {self.address_string()} {fmt % args}")

    def send_html(self, html: str, status: int = 200):
        encoded = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)

        if path in ("/", "/index.html"):
            body = build_index(self.sections, self.repo_root)
            page = PAGE_TEMPLATE.format(title="Deployments Docs", nav=self.nav_html, body=body)
            self.send_html(page)
            return

        if path.startswith("/doc/"):
            rel = path[len("/doc/"):]
            fpath = self.repo_root / rel
            if not fpath.exists() or fpath.suffix.lower() != ".md":
                self.send_html("<h1>404 Not Found</h1>", 404)
                return
            try:
                body = render_markdown(fpath)
            except Exception as exc:
                body = f"<pre>Error rendering {rel}:\n{exc}</pre>"
            title = fpath.stem.replace("-", " ").replace("_", " ").title()
            page = PAGE_TEMPLATE.format(title=title, nav=self.nav_html, body=body)
            self.send_html(page)
            return

        self.send_html("<h1>404 Not Found</h1>", 404)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=7474, help="Port to listen on (default: 7474)")
    parser.add_argument("--root", type=pathlib.Path, default=REPO_ROOT, help="Repo root directory")
    args = parser.parse_args()

    root = args.root.resolve()
    sections = collect_markdown_files(root)
    nav_html = build_nav(sections, root)
    total = sum(len(v) for v in sections.values())

    # Patch class-level state (simple approach for a single-use server)
    DocsHandler.repo_root = root
    DocsHandler.sections = sections
    DocsHandler.nav_html = nav_html

    print(f"Serving {total} Markdown files from {root}")
    print(f"Open: http://localhost:{args.port}")
    print("Press Ctrl-C to stop.\n")

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", args.port), DocsHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
