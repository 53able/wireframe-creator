#!/usr/bin/env python3
"""Prepare VERSION, CHANGELOG.md, and GitHub release notes for a SemVer release."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path

SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
COMMIT_RE = re.compile(r"^(?P<type>[a-z]+)(?:\([^)]*\))?(?:!)?:\s+(?P<title>.+)$")
SECTION_ORDER = [
    "breaking",
    "feat",
    "fix",
    "docs",
    "ci",
    "test",
    "refactor",
    "chore",
    "other",
]
SECTION_TITLES = {
    "breaking": "破壊的変更",
    "feat": "新機能",
    "fix": "修正",
    "docs": "ドキュメント",
    "ci": "CI",
    "test": "テスト",
    "refactor": "リファクタリング",
    "chore": "保守",
    "other": "変更",
}


def parse_version(raw: str) -> tuple[int, int, int]:
    value = raw.strip()
    match = SEMVER_RE.fullmatch(value)
    if not match:
        raise ValueError(
            f"VERSION must contain stable SemVer (X.Y.Z); found {value!r}."
        )
    return tuple(int(part) for part in match.groups())


def bump_version(current: tuple[int, int, int], bump: str) -> str:
    major, minor, patch = current
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError(f"Unsupported bump type: {bump}")


def git_commit_subjects(previous_tag: str) -> list[str]:
    completed = subprocess.run(
        ["git", "log", f"{previous_tag}..HEAD", "--format=%s"],
        check=False,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or "git log failed"
        raise RuntimeError(f"Cannot read changes since {previous_tag}: {message}")
    subjects = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not subjects:
        raise ValueError(
            f"No commits found since {previous_tag}; refusing an empty release."
        )
    return subjects


def categorize(subjects: list[str]) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = defaultdict(list)
    for subject in subjects:
        match = COMMIT_RE.match(subject)
        if not match:
            sections["other"].append(subject)
            continue
        kind = match.group("type")
        title = match.group("title")
        if "BREAKING CHANGE" in subject or "!:" in subject:
            kind = "breaking"
        if kind not in SECTION_TITLES:
            kind = "other"
        sections[kind].append(title)
    return sections


def render_entry(version: str, date: str, sections: dict[str, list[str]]) -> str:
    lines = [f"## {version} - {date}", ""]
    for kind in SECTION_ORDER:
        entries = sections.get(kind, [])
        if not entries:
            continue
        lines.extend([f"### {SECTION_TITLES[kind]}", ""])
        lines.extend(f"- {entry}" for entry in entries)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def prepend_changelog(path: Path, entry: str, version: str) -> None:
    text = path.read_text(encoding="utf-8")
    if re.search(rf"^##\s+{re.escape(version)}(?:\s|$)", text, re.MULTILINE):
        raise ValueError(f"CHANGELOG.md already contains version {version}.")
    marker = "このプロジェクトの主な変更を記録します。\n"
    if marker not in text:
        raise ValueError(
            "CHANGELOG.md does not contain the expected introduction marker."
        )
    updated = text.replace(marker, f"{marker}\n{entry}", 1)
    path.write_text(updated, encoding="utf-8")


def write_release_notes(path: Path, entry: str, version: str) -> None:
    body = entry.split("\n", 1)[1].lstrip()
    text = (
        f"## wireframe-creator v{version}\n\n"
        f"{body}\n"
        "### Agent Skills CLI\n\n"
        "```bash\n"
        "npx skills add 53able/wireframe-creator\n"
        "```\n\n"
        "### Claude Cowork / Claude\n\n"
        f"添付の `wireframe-creator-v{version}.zip` をスキル設定からアップロードしてください。\n"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def append_github_outputs(version: str, previous_tag: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with Path(output_path).open("a", encoding="utf-8") as handle:
        handle.write(f"version={version}\n")
        handle.write(f"tag=v{version}\n")
        handle.write(f"previous_tag={previous_tag}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bump", required=True, choices=("patch", "minor", "major"))
    parser.add_argument("--version-file", type=Path, default=Path("VERSION"))
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    parser.add_argument("--release-notes", type=Path, required=True)
    parser.add_argument(
        "--date", help="Release date in YYYY-MM-DD; defaults to UTC today"
    )
    args = parser.parse_args()

    current = parse_version(args.version_file.read_text(encoding="utf-8"))
    current_text = ".".join(str(part) for part in current)
    previous_tag = f"v{current_text}"
    version = bump_version(current, args.bump)
    date = args.date or datetime.now(UTC).date().isoformat()
    subjects = git_commit_subjects(previous_tag)
    sections = categorize(subjects)
    entry = render_entry(version, date, sections)

    args.version_file.write_text(f"{version}\n", encoding="utf-8")
    prepend_changelog(args.changelog, entry, version)
    write_release_notes(args.release_notes, entry, version)
    append_github_outputs(version, previous_tag)

    print(f"Prepared v{version} from {previous_tag} with {len(subjects)} commit(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
