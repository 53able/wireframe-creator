from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "builder" / "build-wireframe.mjs"
RENDER = ROOT / "scripts" / "render-wireframe-template.py"
VALIDATE = ROOT / "scripts" / "validate-wireframe.py"
EXAMPLE_INPUT = ROOT / "examples" / "wireframe.json"
LABELS_PATH = ROOT / "scripts" / "operation-status-labels.json"
TAILWIND_LICENSE_PATH = ROOT / "assets" / "tailwind.LICENSE.md"

OPERATION_REPORT_RE = re.compile(
    r'<script[^>]*\bdata-operation-report\b[^>]*>(.*?)</script\s*>', re.DOTALL
)
OPERATION_BADGE_RE = re.compile(
    r'<span[^>]*\bclass="[^"]*\boperation-status\b[^"]*"[^>]*>([^<]*)</span>'
)
TAILWIND_STYLE_RE = re.compile(
    r'<style\b(?=[^>]*\bdata-tailwind-css\b)[^>]*>(.*?)</style\s*>', re.IGNORECASE | re.DOTALL
)


class TailwindCssTests(unittest.TestCase):
    def run_script(self, script: Path, *args: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *(str(arg) for arg in args)],
            check=True,
            text=True,
            capture_output=True,
        )

    def run_script_expect_failure(self, script: Path, *args: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *(str(arg) for arg in args)],
            check=False,
            text=True,
            capture_output=True,
        )

    def build_wireframe(self, output: Path, source: Path = EXAMPLE_INPUT) -> str:
        result = subprocess.run(
            ["node", str(BUILD), str(source), str(output)],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        return output.read_text(encoding="utf-8")

    def load_labels(self) -> dict[str, str]:
        return json.loads(LABELS_PATH.read_text(encoding="utf-8"))

    def extract_operation_report(self, source: str) -> dict[str, object]:
        matches = OPERATION_REPORT_RE.findall(source)
        self.assertEqual(len(matches), 1, "expected exactly one embedded operation report")
        return json.loads(matches[0])

    def extract_badges(self, source: str) -> list[str]:
        return [badge.strip() for badge in OPERATION_BADGE_RE.findall(source)]

    def test_build_output_passes_validation_with_explicit_and_auto_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            self.build_wireframe(output)

            explicit = self.run_script(
                VALIDATE, output, "--min-screens", "2", "--require-actions", "--profile", "tailwind", "--json"
            )
            explicit_details = json.loads(explicit.stdout)
            self.assertTrue(explicit_details["ok"])
            self.assertEqual(explicit_details["details"]["profile"], "tailwind")
            self.assertEqual(explicit_details["details"]["profileSource"], "argument")

            auto = self.run_script(
                VALIDATE, output, "--min-screens", "2", "--require-actions", "--json"
            )
            auto_details = json.loads(auto.stdout)
            self.assertTrue(auto_details["ok"])
            self.assertEqual(auto_details["details"]["profile"], "tailwind")
            self.assertEqual(auto_details["details"]["profileSource"], "html")

    def test_generated_html_embeds_single_tailwind_style_with_full_license(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            source = self.build_wireframe(output)

            style_blocks = TAILWIND_STYLE_RE.findall(source)
            self.assertEqual(len(style_blocks), 1)

            license_text = TAILWIND_LICENSE_PATH.read_text(encoding="utf-8").strip()
            self.assertIn(license_text, style_blocks[0])
            self.assertRegex(source, r"<style\b[^>]*\bdata-tailwind-version=4\.3\.3\b[^>]*>")

    def test_operation_report_matches_visible_badges_and_status_labels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            source = self.build_wireframe(output)

            report = self.extract_operation_report(source)
            labels = self.load_labels()
            operations = report["operations"]
            self.assertTrue(operations)

            expected_badges = [labels[operation["status"]] for operation in operations]
            actual_badges = self.extract_badges(source)
            self.assertEqual(actual_badges, expected_badges)

            result = self.run_script(
                VALIDATE, output, "--min-screens", "2", "--require-actions", "--json"
            )
            details = json.loads(result.stdout)["details"]
            self.assertEqual(details["operationCount"], len(operations))

    def test_validator_rejects_html_with_tampered_operation_badge(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "wireframe.html"
            source = self.build_wireframe(output)

            labels = self.load_labels()
            report = self.extract_operation_report(source)
            operations = report["operations"]
            original_label = labels[operations[0]["status"]]
            other_label = next(label for label in labels.values() if label != original_label)
            self.assertIn(original_label, source)

            tampered = source.replace(
                f'operation-status shrink-0 rounded-full px-2 py-1 text-xs font-medium">{original_label}<',
                f'operation-status shrink-0 rounded-full px-2 py-1 text-xs font-medium">{other_label}<',
                1,
            )
            self.assertNotEqual(tampered, source)
            output.write_text(tampered, encoding="utf-8")

            result = self.run_script_expect_failure(VALIDATE, output, "--profile", "tailwind")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Operation status labels do not match the embedded report.", result.stderr)

    def test_pico_html_cannot_be_forced_into_tailwind_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pico-wireframe.html"
            self.run_script(RENDER, "--output", output)
            source = re.sub(r"\{\{[^{}]+\}\}", "Sample", output.read_text(encoding="utf-8"))
            output.write_text(source, encoding="utf-8")

            pico_default = self.run_script(VALIDATE, output, "--json")
            self.assertEqual(json.loads(pico_default.stdout)["details"]["profile"], "pico")

            forced_tailwind = self.run_script_expect_failure(VALIDATE, output, "--profile", "tailwind")
            self.assertEqual(forced_tailwind.returncode, 1)
            self.assertIn(
                "HTML must contain exactly one complete data-tailwind-css style element.",
                forced_tailwind.stderr,
            )


if __name__ == "__main__":
    unittest.main()
