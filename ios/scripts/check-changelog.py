#!/usr/bin/env python3
"""Validate the release-note format and descending semantic versions."""
import datetime
from pathlib import Path
import re

text = Path(__file__).resolve().parent.parent.joinpath("CHANGELOG.md").read_text(encoding="utf-8")
versions = []
group = False
entries = 0
for line in text.splitlines():
    if line.startswith("## "):
        match = re.fullmatch(r"## (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*) - (\d{4}-\d{2}-\d{2})", line)
        if not match:
            raise SystemExit(f"Invalid version heading: {line}")
        if versions and entries == 0:
            raise SystemExit("Each version needs a changelog entry")
        version = tuple(map(int, match.groups()[:3]))
        datetime.date.fromisoformat(match[4])
        if versions and version >= versions[-1]:
            raise SystemExit("Changelog versions must descend without duplicates")
        versions.append(version)
        group, entries = False, 0
    elif line.startswith("### "):
        if not versions or line not in {"### Added", "### Changed", "### Fixed", "### Removed"}:
            raise SystemExit(f"Invalid group: {line}")
        group = True
    elif versions and line:
        if not group or not (line.startswith("- ") or line.startswith("  ")):
            raise SystemExit(f"Invalid changelog entry: {line}")
        if line.startswith("- "):
            entries += 1
if not versions or not entries:
    raise SystemExit("Changelog needs a version with entries")
print("PASS: changelog format and version order")
