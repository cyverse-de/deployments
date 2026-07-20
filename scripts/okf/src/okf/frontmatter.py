"""Parsing of YAML frontmatter blocks in OKF documents."""

from dataclasses import dataclass

import yaml


@dataclass(frozen=True)
class Frontmatter:
    """Result of looking for a frontmatter block at the top of a document."""

    present: bool
    data: dict | None = None
    error: str | None = None
    body_start: int = 1


def parse(text: str) -> Frontmatter:
    """Parse the leading frontmatter block, distinguishing absent from invalid."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return Frontmatter(present=False)
    for i in range(1, len(lines)):
        if lines[i].strip() != "---":
            continue
        raw = "\n".join(lines[1:i])
        body_start = i + 2
        try:
            data = yaml.safe_load(raw)
        except yaml.YAMLError as exc:
            message = str(exc).replace("\n", " ")
            return Frontmatter(
                True, error=f"invalid YAML: {message}", body_start=body_start
            )
        if not isinstance(data, dict):
            return Frontmatter(
                True,
                error="frontmatter is empty or not a YAML mapping",
                body_start=body_start,
            )
        return Frontmatter(True, data=data, body_start=body_start)
    return Frontmatter(
        True, error="unterminated frontmatter block", body_start=len(lines) + 1
    )
