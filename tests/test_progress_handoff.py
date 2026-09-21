from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPDATE = ROOT / "scripts" / "update-progress.py"
SERVE = ROOT / "scripts" / "serve-preview.py"


class ProgressHandoffTests(unittest.TestCase):
    def run_update(self, *args: object, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(UPDATE), *(str(arg) for arg in args)],
            check=check,
            text=True,
            capture_output=True,
        )

    def set_output(self, preview: Path, output_dir: Path, slug: str) -> Path:
        result = self.run_update(
            "set-output",
            preview,
            "--output-dir",
            output_dir,
            "--slug",
            slug,
        )
        line = next(
            value
            for value in result.stdout.splitlines()
            if value.startswith("CANONICAL_HTML=")
        )
        return Path(line.removeprefix("CANONICAL_HTML="))

    def complete_steps(self, preview: Path) -> None:
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
                self.run_update("set", preview, "--step", step, "--state", "running")
            self.run_update("set", preview, "--step", step, "--state", "pass")
        self.run_update(
            "set", preview, "--step", "finalization", "--state", "running"
        )

    def test_browser_progress_schema_matches_generated_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            preview = Path(directory) / ".sample-wireframe-preview.html"
            self.run_update("init", preview, "--mode", "new", "--title", "Sample")

            source = preview.read_text(encoding="utf-8")
            state_match = re.search(
                r'<script type="application/json" data-generation-progress-state>'
                r"(.*?)</script>",
                source,
                re.DOTALL,
            )
            self.assertIsNotNone(state_match)
            assert state_match is not None
            state = json.loads(state_match.group(1))

            client = (ROOT / "assets" / "hot-reload-client.fragment.html").read_text(
                encoding="utf-8"
            )
            ids_match = re.search(r"const expectedIds = (\[[^;]+\]);", client)
            labels_match = re.search(r"const expectedLabels = (\[[^;]+\]);", client)
            self.assertIsNotNone(ids_match)
            self.assertIsNotNone(labels_match)
            assert ids_match is not None and labels_match is not None
            expected_ids = ast.literal_eval(ids_match.group(1))
            expected_labels = ast.literal_eval(labels_match.group(1))

            self.assertEqual(expected_ids, [step["id"] for step in state["steps"]])
            self.assertEqual(
                expected_labels, [step["label"] for step in state["steps"]]
            )

    def test_finalizes_to_timestamped_canonical_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preview = root / ".sample-wireframe-preview.html"
            self.run_update("init", preview, "--mode", "new", "--title", "Sample")
            self.complete_steps(preview)
            before = datetime.now().astimezone().replace(tzinfo=None)
            before = before.replace(microsecond=(before.microsecond // 1000) * 1000)
            canonical = self.set_output(preview, root, "sample")
            after = datetime.now().astimezone().replace(tzinfo=None)
            after = after.replace(microsecond=(after.microsecond // 1000) * 1000)

            match = re.fullmatch(
                r"sample-wireframe-(\d{8}-\d{6}-\d{3})\.html", canonical.name
            )
            self.assertIsNotNone(match)
            assert match is not None
            completed_at = datetime.strptime(match.group(1), "%Y%m%d-%H%M%S-%f")
            self.assertLessEqual(before, completed_at)
            self.assertLessEqual(completed_at, after)

            prepared = preview.read_text(encoding="utf-8")
            self.assertIn('"id":"context"', prepared)
            self.assertIn(canonical.resolve().as_uri(), prepared)
            self.assertIn(canonical.name, prepared)
            self.assertFalse(canonical.exists())

            completed = self.run_update("finalize", preview, "--output", canonical)
            self.assertIn(f"CANONICAL_HTML={canonical.resolve()}", completed.stdout)
            self.run_update("verify-final", canonical)
            self.assertEqual(preview.read_bytes(), canonical.read_bytes())
            self.assertNotIn(
                "data-generation-progress", canonical.read_text(encoding="utf-8")
            )

    def test_rejects_invalid_slug(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preview = root / ".sample-wireframe-preview.html"
            self.run_update("init", preview, "--mode", "new", "--title", "Sample")

            result = self.run_update(
                "set-output",
                preview,
                "--output-dir",
                root,
                "--slug",
                "Invalid Slug",
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("lowercase kebab-case", result.stderr)

    def test_finalize_refuses_to_clobber_racing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preview = root / ".sample-wireframe-preview.html"
            self.run_update("init", preview, "--mode", "new", "--title", "Sample")
            self.complete_steps(preview)
            canonical = self.set_output(preview, root, "sample")
            canonical.write_text("created by another process", encoding="utf-8")

            result = self.run_update(
                "finalize", preview, "--output", canonical, check=False
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Refusing to overwrite", result.stderr)
            self.assertEqual(
                canonical.read_text(encoding="utf-8"), "created by another process"
            )
            self.assertIn(
                "WIREFRAME_PROGRESS_START", preview.read_text(encoding="utf-8")
            )

    def test_static_download_is_blocked_until_finalization_and_uses_final_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preview = root / ".sample-wireframe-preview.html"
            self.run_update("init", preview, "--mode", "new", "--title", "Sample")

            server = subprocess.Popen(
                [sys.executable, str(SERVE), str(preview), "--port", "0"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert server.stdout is not None
                first_line = server.stdout.readline().strip()
                self.assertTrue(first_line.startswith("PREVIEW_URL="), first_line)
                preview_url = first_line.removeprefix("PREVIEW_URL=")
                early_download_url = (
                    f"{preview_url}__wireframe/static?filename="
                    "sample-wireframe-20260922-130745-123.html"
                )

                with self.assertRaises(urllib.error.HTTPError) as early_error:
                    urllib.request.urlopen(early_download_url, timeout=5)
                self.assertEqual(early_error.exception.code, 409)
                early_error.exception.close()

                self.complete_steps(preview)
                canonical = self.set_output(preview, root, "sample")
                self.run_update("finalize", preview, "--output", canonical)
                download_url = (
                    f"{preview_url}__wireframe/static?filename={canonical.name}"
                )

                with urllib.request.urlopen(download_url, timeout=5) as response:
                    payload = response.read()
                    disposition = response.headers["Content-Disposition"]
                self.assertEqual(payload, canonical.read_bytes())
                self.assertIn("attachment", disposition)
                self.assertIn(canonical.name, disposition)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                if server.stdout is not None:
                    server.stdout.close()
                if server.stderr is not None:
                    server.stderr.close()


if __name__ == "__main__":
    unittest.main()
