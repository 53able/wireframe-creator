from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "scripts" / "render-wireframe-template.py"
UPDATE = ROOT / "scripts" / "update-progress.py"
VALIDATE = ROOT / "scripts" / "validate-wireframe.py"


class PicoCssTests(unittest.TestCase):
    def run_script(self, script: Path, *args: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *(str(arg) for arg in args)],
            check=True,
            text=True,
            capture_output=True,
        )

    def test_renderer_embeds_pinned_css_and_complete_license(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            self.run_script(RENDER, "--output", output)
            source = output.read_text(encoding="utf-8")

            self.assertEqual(source.count("data-pico-css"), 1)
            self.assertIn('data-pico-version="2.1.1"', source)
            self.assertIn("MIT License", source)
            self.assertIn("Copyright (c) 2019-2024 Pico", source)
            self.assertIn("Permission is hereby granted", source)
            self.assertNotIn("{{PICO_STYLE}}", source)
            self.assertNotIn('<link rel="stylesheet"', source)

    def test_rendered_template_passes_structural_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            self.run_script(RENDER, "--output", output)
            source = output.read_text(encoding="utf-8")
            source = re.sub(r"\{\{[^{}]+\}\}", "Sample", source)
            output.write_text(source, encoding="utf-8")

            result = self.run_script(
                VALIDATE,
                output,
                "--min-screens",
                "2",
                "--require-actions",
                "--json",
            )
            self.assertIn('"ok": true', result.stdout)
            self.assertIn('"picoVersion": "2.1.1"', result.stdout)

    def test_progress_shell_and_final_output_keep_pico_license(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preview = root / ".sample-wireframe-preview.html"
            self.run_script(UPDATE, "init", preview, "--mode", "new", "--title", "Sample")
            initialized = preview.read_text(encoding="utf-8")
            self.assertEqual(initialized.count("<style data-pico-css"), 1)
            self.assertIn('<html lang="ja" data-theme="light">', initialized)
            self.assertIn('<meta name="color-scheme" content="light">', initialized)
            self.assertIn("Permission is hereby granted", initialized)

            for step in (
                "input",
                "context",
                "brief",
                "design",
                "html-generation",
                "structural-validation",
                "browser-validation",
            ):
                if step != "input":
                    self.run_script(UPDATE, "set", preview, "--step", step, "--state", "running")
                self.run_script(UPDATE, "set", preview, "--step", step, "--state", "pass")
            self.run_script(UPDATE, "set", preview, "--step", "finalization", "--state", "running")
            result = self.run_script(
                UPDATE,
                "set-output",
                preview,
                "--output-dir",
                root,
                "--slug",
                "sample",
            )
            canonical = Path(
                next(
                    line.removeprefix("CANONICAL_HTML=")
                    for line in result.stdout.splitlines()
                    if line.startswith("CANONICAL_HTML=")
                )
            )
            self.run_script(UPDATE, "finalize", preview, "--output", canonical)
            finalized = canonical.read_text(encoding="utf-8")
            self.assertEqual(finalized.count("<style data-pico-css"), 1)
            self.assertIn("Permission is hereby granted", finalized)
            self.assertNotIn("data-generation-progress-style", finalized)

    def test_validator_rejects_missing_pico_css(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            html = Path(directory) / "plain.html"
            html.write_text(
                "<!doctype html><html lang='ja'><head><meta name='viewport' content='width=device-width'>"
                "<title>Plain</title><style>:focus-visible{outline:1px solid}</style></head>"
                "<body><main><section data-screen-id='start' data-start-screen aria-label='Start'>"
                "<ul data-assumptions><li>none</li></ul><ul data-open-questions><li>none</li></ul>"
                "</section></main><script>void 0</script></body></html>",
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(VALIDATE), str(html)],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Expected exactly one inline Pico CSS style", result.stderr)


if __name__ == "__main__":
    unittest.main()
