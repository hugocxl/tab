#!/usr/bin/env python3
"""Deterministic product-oriented commit linter and automatic CHANGELOG.md updater.

Commit format:
  Added: <One user-facing sentence.>     -> minor bump, ### Added
  Changed: <One user-facing sentence.>   -> minor bump, ### Changed
  Removed: <One user-facing sentence.>   -> minor bump, ### Removed
  Improved: <One user-facing sentence.>  -> patch bump, ### Changed
  Fixed: <One user-facing sentence.>     -> patch bump, ### Fixed

Usage:
  commit-lint.py <msg-file>
  commit-lint.py --update-changelog <msg-file>
  commit-lint.py --range <git-rev-range>
"""
import datetime
from pathlib import Path
import re
import subprocess
import sys

PREFIXES = {
    "Added": ("minor", "Added"),
    "Changed": ("minor", "Changed"),
    "Removed": ("minor", "Removed"),
    "Improved": ("patch", "Changed"),
    "Fixed": ("patch", "Fixed"),
}

EXEMPT_RE = re.compile(r"^(Merge |Revert \"|Initial commit)")
SUBJECT_RE = re.compile(r"^(Added|Changed|Removed|Improved|Fixed): ([A-Z].+)$")
DEV_JARGON_RE = re.compile(
    r"(^|\s)(feat|fix|chore|refactor|ci|docs|style|perf|build|test|wip|fixup!|squash!)(\(|:)"
    r"|\b\S+\.(swift|ts|tsx|js|mjs|cjs|py|sh|yml|yaml|json|pbxproj|xcconfig|md)\b",
    re.IGNORECASE,
)
VERSION_RE = re.compile(r"^## (\d+)\.(\d+)\.(\d+) - \d{4}-\d{2}-\d{2}$", re.MULTILINE)
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def extract_subject(raw: str) -> str:
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return stripped
    return ""


def validate_subject(subject: str) -> tuple[str | None, str | None, str | None]:
    """Return (prefix, description, error). Exempt commits return (None, None, None)."""
    if not subject:
        return None, None, "Commit message is empty."
    if EXEMPT_RE.match(subject):
        return None, None, None
    match = SUBJECT_RE.fullmatch(subject)
    if not match:
        return None, None, (
            f"Invalid commit subject: {subject!r}\n"
            "Expected: <Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence starting with a capital letter>"
        )
    prefix, desc = match.groups()
    if len(desc) < 8 or len(desc) > 120:
        return None, None, f"Commit description must be 8-120 characters (got {len(desc)}): {subject!r}"
    if DEV_JARGON_RE.search(desc):
        return None, None, (
            f"Write commit messages for users, without file names or dev prefixes: {subject!r}"
        )
    return prefix, desc, None


def git(*args: str, cwd: Path) -> str:
    res = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else ""


def highest_version(root: Path, changelog_text: str) -> tuple[int, int, int]:
    versions: list[tuple[int, int, int]] = []
    for m in VERSION_RE.finditer(changelog_text):
        versions.append((int(m[1]), int(m[2]), int(m[3])))
    for tag in git("tag", "--list", "v*", cwd=root).splitlines():
        m = TAG_RE.fullmatch(tag.strip())
        if m:
            versions.append((int(m[1]), int(m[2]), int(m[3])))
    return max(versions) if versions else (0, 0, 0)


def head_changelog_version(root: Path) -> tuple[int, int, int] | None:
    text = git("show", "HEAD:CHANGELOG.md", cwd=root)
    if not text:
        return None
    m = VERSION_RE.search(text)
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


def bump(version: tuple[int, int, int], kind: str) -> tuple[int, int, int]:
    major, minor, patch = version
    if kind == "minor":
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def update_changelog(root: Path, prefix: str, desc: str) -> str | None:
    changelog = root / "CHANGELOG.md"
    if not changelog.exists():
        return None
    text = changelog.read_text(encoding="utf-8")
    current_match = VERSION_RE.search(text)
    current_ver = (int(current_match[1]), int(current_match[2]), int(current_match[3])) if current_match else None
    head_ver = head_changelog_version(root)
    # If CHANGELOG.md already has an entry newer than HEAD (e.g., manual bump or amend), keep it.
    if current_ver and (head_ver is None or current_ver > head_ver):
        return f"{current_ver[0]}.{current_ver[1]}.{current_ver[2]}"

    bump_kind, section = PREFIXES[prefix]
    next_ver = bump(highest_version(root, text), bump_kind)
    ver_str = f"{next_ver[0]}.{next_ver[1]}.{next_ver[2]}"
    today = datetime.date.today().isoformat()
    entry = desc if desc.endswith(".") else f"{desc}."
    block = f"## {ver_str} - {today}\n\n### {section}\n\n- {entry}\n\n"

    if current_match:
        new_text = text[:current_match.start()] + block + text[current_match.start():]
    else:
        header = text.rstrip() + "\n\n" if text.strip() else "# Changelog\n\n"
        new_text = header + block

    changelog.write_text(new_text, encoding="utf-8")
    return ver_str


def lint_range(root: Path, rev_range: str) -> int:
    out = git("log", "--no-merges", "--first-parent", "--format=%H%x09%s", rev_range, cwd=root)
    errors = []
    for line in out.splitlines():
        if not line.strip():
            continue
        sha, subject = line.split("\t", 1)
        _, _, err = validate_subject(subject)
        if err:
            errors.append(f"{sha[:8]}: {err}")
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1
    print(f"PASS: commit messages in {rev_range}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    root = repo_root()
    if len(args) == 2 and args[0] == "--range":
        return lint_range(root, args[1])
    if len(args) == 2 and args[0] == "--update-changelog":
        subject = extract_subject(Path(args[1]).read_text(encoding="utf-8"))
        prefix, desc, err = validate_subject(subject)
        if err:
            print(err, file=sys.stderr)
            return 1
        if prefix and desc:
            ver = update_changelog(root, prefix, desc)
            if ver:
                print(ver)
        return 0
    if len(args) == 1:
        subject = extract_subject(Path(args[0]).read_text(encoding="utf-8"))
        _, _, err = validate_subject(subject)
        if err:
            print(err, file=sys.stderr)
            return 1
        return 0
    print("Usage: commit-lint.py [--update-changelog] <msg-file> | --range <rev-range>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
