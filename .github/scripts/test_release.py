#!/usr/bin/env python3
"""Tests for release preparation and skill packaging."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load_module("prepare_release", "prepare-release.py")
package = load_module("package_skill", "package-skill.py")


class PrepareReleaseTests(unittest.TestCase):
    def test_semver_bumps(self) -> None:
        current = prepare.parse_version("1.2.3\n")
        self.assertEqual(prepare.bump_version(current, "patch"), "1.2.4")
        self.assertEqual(prepare.bump_version(current, "minor"), "1.3.0")
        self.assertEqual(prepare.bump_version(current, "major"), "2.0.0")

    def test_changelog_sections(self) -> None:
        sections = prepare.categorize(
            [
                "feat: add export",
                "fix(parser): reject empty input",
                "unstructured change",
            ]
        )
        rendered = prepare.render_entry("1.1.0", "2026-09-20", sections)
        self.assertIn("## 1.1.0 - 2026-09-20", rendered)
        self.assertIn("### 新機能", rendered)
        self.assertIn("- add export", rendered)
        self.assertIn("### 修正", rendered)
        self.assertIn("### 変更", rendered)


class PackageSkillTests(unittest.TestCase):
    def test_collects_only_skill_runtime_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in package.ROOT_FILES:
                (root / name).write_text("1.0.0\n" if name == "VERSION" else name)
            for name in package.RESOURCE_DIRS:
                (root / name).mkdir()
                (root / name / "kept.txt").write_text(name)
            (root / "README.md").write_text("repository documentation")
            (root / "scripts" / "__pycache__").mkdir()
            (root / "scripts" / "__pycache__" / "ignored.pyc").write_bytes(b"cache")

            files = package.collect_files(root)
            relative = {path.relative_to(root).as_posix() for path in files}

            self.assertIn("SKILL.md", relative)
            self.assertIn("assets/kept.txt", relative)
            self.assertNotIn("README.md", relative)
            self.assertNotIn("scripts/__pycache__/ignored.pyc", relative)

    def test_archive_has_single_top_level_folder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in package.ROOT_FILES:
                (root / name).write_text("1.0.0\n" if name == "VERSION" else name)
            for name in package.RESOURCE_DIRS:
                (root / name).mkdir()
                (root / name / "file.txt").write_text(name)
            archive_path = root / "skill.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for path in package.collect_files(root):
                    package.add_file(archive, root, path)
            with zipfile.ZipFile(archive_path) as archive:
                self.assertIn("wireframe-creator/SKILL.md", archive.namelist())
                self.assertTrue(
                    all(
                        name.startswith("wireframe-creator/")
                        for name in archive.namelist()
                    )
                )


if __name__ == "__main__":
    unittest.main()
