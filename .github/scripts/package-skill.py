#!/usr/bin/env python3
"""Build a deterministic, skill-only ZIP for Claude and other Agent Skills clients."""

from __future__ import annotations

import argparse
import hashlib
import stat
import zipfile
from pathlib import Path, PurePosixPath

SKILL_NAME = "wireframe-creator"
ROOT_FILES = ("SKILL.md", "LICENSE", "VERSION")
RESOURCE_DIRS = ("assets", "references", "scripts")
EXCLUDED_PARTS = {"__pycache__", ".DS_Store"}
EXCLUDED_SUFFIXES = {".pyc", ".pyo"}
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for name in ROOT_FILES:
        path = root / name
        if not path.is_file():
            raise FileNotFoundError(f"Required release file is missing: {path}")
        files.append(path)

    for directory_name in RESOURCE_DIRS:
        directory = root / directory_name
        if not directory.is_dir():
            raise FileNotFoundError(
                f"Required release directory is missing: {directory}"
            )
        for path in sorted(directory.rglob("*")):
            relative = path.relative_to(root)
            if path.is_symlink():
                raise ValueError(
                    f"Symlinks are not allowed in the release ZIP: {relative}"
                )
            if not path.is_file():
                continue
            if any(part in EXCLUDED_PARTS for part in relative.parts):
                continue
            if path.suffix in EXCLUDED_SUFFIXES:
                continue
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def add_file(archive: zipfile.ZipFile, root: Path, path: Path) -> None:
    relative = PurePosixPath(path.relative_to(root).as_posix())
    archive_name = str(PurePosixPath(SKILL_NAME) / relative)
    info = zipfile.ZipInfo(archive_name, FIXED_TIMESTAMP)
    source_mode = path.stat().st_mode
    mode = 0o755 if source_mode & stat.S_IXUSR else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(info, path.read_bytes())


def validate_version(root: Path, version: str) -> None:
    actual = (root / "VERSION").read_text(encoding="utf-8").strip()
    if actual != version:
        raise ValueError(
            f"Requested version {version} does not match VERSION ({actual})."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--version", required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    args = parser.parse_args()

    root = args.root.resolve()
    validate_version(root, args.version)
    files = collect_files(root)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / f"{SKILL_NAME}-v{args.version}.zip"

    with zipfile.ZipFile(output, "w") as archive:
        for path in files:
            add_file(archive, root, path)

    with zipfile.ZipFile(output) as archive:
        names = archive.namelist()
        required_skill = f"{SKILL_NAME}/SKILL.md"
        if required_skill not in names:
            raise RuntimeError(f"Archive is missing {required_skill}.")
        if any(not name.startswith(f"{SKILL_NAME}/") for name in names):
            raise RuntimeError(
                "Archive contains files outside the top-level skill directory."
            )
        bad_member = archive.testzip()
        if bad_member:
            raise RuntimeError(f"Archive integrity check failed at {bad_member}.")

    print(f"artifact={output}")
    print(f"sha256={sha256(output)}")
    print(f"files={len(files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
