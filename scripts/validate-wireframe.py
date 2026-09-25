#!/usr/bin/env python3
"""Validate the structural contract of a self-contained HTML wireframe."""

from __future__ import annotations

import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

from pico_assets import PICO_VERSION, validate_pico_style


PLACEHOLDER_RE = re.compile(r"\{\{[^{}]+\}\}")
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class WireframeParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.html_lang: str | None = None
        self.has_viewport = False
        self.has_title = False
        self.in_title = False
        self.title_parts: list[str] = []
        self.main_count = 0
        self.screen_ids: list[str] = []
        self.start_screens: list[str] = []
        self.action_targets: list[str] = []
        self.nav_targets: list[str] = []
        self.external_references: list[str] = []
        self.inline_script_count = 0
        self.external_script_count = 0
        self.stylesheet_links = 0
        self.pico_version: str | None = None
        self.tailwind_version: str | None = None
        self.assumptions_blocks = 0
        self.open_question_blocks = 0
        self.current_screen: str | None = None
        self.screen_heading_count: dict[str, int] = {}
        self.screen_aria_labelled: set[str] = set()
        self._screen_stack: list[str | None] = []
        self.operation_rows: list[tuple[str, str, str]] = []
        self.operation_reports: list[str] = []
        self._reading_operation_report = False
        self._operation_report_parts: list[str] = []
        self.operation_badges: list[str] = []
        self._reading_operation_badge = False

    @staticmethod
    def attrs_dict(attrs: list[tuple[str, str | None]]) -> dict[str, str]:
        return {key: value or "" for key, value in attrs}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = self.attrs_dict(attrs)

        if tag == "html":
            self.html_lang = values.get("lang") or None
        elif tag == "meta" and values.get("name", "").lower() == "viewport":
            self.has_viewport = True
        elif tag == "title":
            self.has_title = True
            self.in_title = True
        elif tag == "main":
            self.main_count += 1

        if tag == "script":
            if "data-operation-report" in values:
                self._reading_operation_report = True
                self._operation_report_parts = []
            if values.get("src"):
                self.external_script_count += 1
            else:
                self.inline_script_count += 1
        if tag == "link" and "stylesheet" in values.get("rel", "").lower():
            self.stylesheet_links += 1
        if tag == "style" and "data-pico-css" in values:
            self.pico_version = values.get("data-pico-version") or None
        if tag == "style" and "data-tailwind-css" in values:
            self.tailwind_version = values.get("data-tailwind-version") or None

        for attr in ("src", "href"):
            value = values.get(attr, "").strip()
            if not value or value.startswith(("#", "data:", "mailto:", "tel:")):
                continue
            parsed = urlparse(value)
            if parsed.scheme in {"http", "https"} or value.startswith("//"):
                self.external_references.append(value)

        if tag not in VOID_TAGS:
            self._screen_stack.append(self.current_screen)
        screen_id = values.get("data-screen-id")
        if screen_id:
            self.current_screen = screen_id
            self.screen_ids.append(screen_id)
            self.screen_heading_count.setdefault(screen_id, 0)
            if "data-start-screen" in values:
                self.start_screens.append(screen_id)
            if values.get("aria-label") or values.get("aria-labelledby"):
                self.screen_aria_labelled.add(screen_id)

        if self.current_screen and tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self.screen_heading_count[self.current_screen] = self.screen_heading_count.get(self.current_screen, 0) + 1

        action_target = values.get("data-action-target")
        if action_target:
            self.action_targets.append(action_target)
        nav_target = values.get("data-nav-target")
        if nav_target:
            self.nav_targets.append(nav_target)
        if "data-operation-id" in values:
            self.operation_rows.append((values["data-operation-id"], values.get("data-operation-status", ""), values.get("data-operation-expected", "")))
        if tag == "span" and "operation-status" in values.get("class", "").split():
            self._reading_operation_badge = True
            self.operation_badges.append("")
        if "data-assumptions" in values:
            self.assumptions_blocks += 1
        if "data-open-questions" in values:
            self.open_question_blocks += 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "script" and self._reading_operation_report:
            self.operation_reports.append("".join(self._operation_report_parts))
            self._reading_operation_report = False
        if tag == "span" and self._reading_operation_badge:
            self._reading_operation_badge = False
        if tag == "title":
            self.in_title = False
        if tag not in VOID_TAGS and self._screen_stack:
            self.current_screen = self._screen_stack.pop()

    def handle_data(self, data: str) -> None:
        if self._reading_operation_report:
            self._operation_report_parts.append(data)
        if self._reading_operation_badge:
            self.operation_badges[-1] += data
        if self.in_title:
            self.title_parts.append(data)


class ValidationResult:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.details: dict[str, object] = {}

    @property
    def ok(self) -> bool:
        return not self.errors

    def as_dict(self) -> dict[str, object]:
        return {
            "ok": self.ok,
            "path": str(self.path),
            "errors": self.errors,
            "warnings": self.warnings,
            "details": self.details,
        }


SCRIPT_DIR = Path(__file__).resolve().parent
OPERATION_STATUS_LABELS_PATH = SCRIPT_DIR / "operation-status-labels.json"
TAILWIND_LICENSE_PATH = SCRIPT_DIR.parent / "assets" / "tailwind.LICENSE.md"
PROFILES = ("pico", "tailwind")


def load_operation_status_labels(path: Path = OPERATION_STATUS_LABELS_PATH) -> dict[str, str]:
    """Load the shared status -> visible label map (also consumed by builder/build-wireframe.mjs)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data or not all(
        isinstance(key, str) and key and isinstance(value, str) and value for key, value in data.items()
    ):
        raise ValueError(f"{path.name} must be a non-empty object of status -> label strings")
    return data


def resolve_profile(parser: WireframeParser, requested: str | None) -> tuple[str, str]:
    """Return (profile, source). An explicit caller choice always wins over the HTML self-declaration."""
    if requested is not None:
        return requested, "argument"
    return ("tailwind" if parser.tailwind_version is not None else "pico"), "html"


def validate_common_source(source: str, result: ValidationResult) -> None:
    """Style-independent checks on the raw source text (run before HTML parsing)."""
    if not re.match(r"\s*<!doctype\s+html", source, re.IGNORECASE):
        result.errors.append("Missing <!doctype html> declaration.")

    placeholders = sorted(set(PLACEHOLDER_RE.findall(source)))
    if placeholders:
        result.errors.append(
            "Unresolved template placeholders remain: " + ", ".join(placeholders[:10])
        )


def validate_common(parser: WireframeParser, result: ValidationResult, min_screens: int, require_actions: bool) -> None:
    """Style-independent contract: document shell, screens, transitions, self-containment."""
    if not parser.html_lang:
        result.errors.append("The <html> element must declare a lang attribute.")
    if not parser.has_viewport:
        result.errors.append("Missing viewport meta tag for responsive rendering.")
    if not parser.has_title or not "".join(parser.title_parts).strip():
        result.errors.append("Missing non-empty <title>.")
    if parser.main_count != 1:
        result.errors.append(f"Expected exactly one <main>; found {parser.main_count}.")
    if len(parser.screen_ids) < min_screens:
        result.errors.append(
            f"Expected at least {min_screens} data-screen-id elements; found {len(parser.screen_ids)}."
        )

    duplicate_ids = sorted({item for item in parser.screen_ids if parser.screen_ids.count(item) > 1})
    if duplicate_ids:
        result.errors.append("Duplicate data-screen-id values: " + ", ".join(duplicate_ids))

    if len(parser.start_screens) != 1:
        result.errors.append(
            f"Expected exactly one data-start-screen element; found {len(parser.start_screens)}."
        )

    known_screens = set(parser.screen_ids)
    unknown_targets = sorted((set(parser.action_targets) | set(parser.nav_targets)) - known_screens)
    if unknown_targets:
        result.errors.append("Unknown transition targets: " + ", ".join(unknown_targets))

    if require_actions and not parser.action_targets:
        result.errors.append("No data-action-target transitions found, but --require-actions was set.")

    screens_without_heading = sorted(
        screen_id
        for screen_id in known_screens
        if parser.screen_heading_count.get(screen_id, 0) == 0
        and screen_id not in parser.screen_aria_labelled
    )
    if screens_without_heading:
        result.errors.append(
            "Screens require a heading or accessible label: " + ", ".join(screens_without_heading)
        )

    if parser.external_references:
        result.errors.append(
            "External dependencies are not allowed: "
            + ", ".join(sorted(set(parser.external_references))[:10])
        )
    if parser.external_script_count:
        result.errors.append("External <script src> dependencies are not allowed.")
    if parser.stylesheet_links:
        result.errors.append("External or linked stylesheets are not allowed; inline CSS instead.")


def validate_common_review_blocks(parser: WireframeParser, result: ValidationResult) -> None:
    """Style-independent review content: assumptions and open questions."""
    if parser.assumptions_blocks == 0:
        result.errors.append("Missing an element with data-assumptions.")
    if parser.open_question_blocks == 0:
        result.errors.append("Missing an element with data-open-questions.")


def validate_common_warnings(source: str, parser: WireframeParser, result: ValidationResult) -> None:
    if not re.search(r":focus-visible|:focus\b", source):
        result.warnings.append("No explicit keyboard focus style was detected.")
    if not parser.inline_script_count and parser.action_targets:
        result.warnings.append("Transitions exist, but no inline script was detected to operate them.")


def validate_pico_profile(source: str, parser: WireframeParser, result: ValidationResult) -> int:
    """Pico profile: pinned, license-complete inline Pico CSS. Returns the verified operation count (always 0)."""
    try:
        validate_pico_style(source)
    except ValueError as exc:
        result.errors.append(str(exc))
    return 0


def _validate_tailwind_style(source: str, parser: WireframeParser, result: ValidationResult) -> None:
    blocks = re.findall(
        r'<style\b(?=[^>]*\bdata-tailwind-css\b)[^>]*>(.*?)</style\s*>',
        source,
        re.IGNORECASE | re.DOTALL,
    )
    try:
        license_text = TAILWIND_LICENSE_PATH.read_text(encoding="utf-8").strip()
    except OSError as exc:
        result.errors.append(f"Cannot load the Tailwind license notice for validation: {exc}")
        return
    if len(blocks) != 1:
        result.errors.append("HTML must contain exactly one complete data-tailwind-css style element.")
    elif not parser.tailwind_version:
        result.errors.append("The data-tailwind-css style element must declare data-tailwind-version.")
    elif license_text not in blocks[0]:
        result.errors.append("Inline Tailwind CSS must contain the complete MIT license notice.")
    elif not re.search(r"tailwindcss v" + re.escape(parser.tailwind_version) + r"\b", blocks[0]):
        result.errors.append("Inline Tailwind CSS version does not match data-tailwind-version.")
    elif re.search(r"@import\b|url\s*\(\s*['\"]?\s*(?:https?:|//)", blocks[0], re.IGNORECASE):
        result.errors.append("Inline Tailwind CSS must not reference external assets.")


def _validate_operation_report(parser: WireframeParser, result: ValidationResult) -> int:
    if len(parser.operation_reports) != 1:
        result.errors.append(f"Expected one embedded operation report; found {len(parser.operation_reports)}.")
        return 0
    try:
        labels = load_operation_status_labels()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        result.errors.append(f"Cannot load shared operation status labels: {exc}")
        return 0
    known_screens = set(parser.screen_ids)
    try:
        report = json.loads(parser.operation_reports[0])
        operations = report["operations"]
        if report.get("version") != 1 or not isinstance(operations, list):
            raise ValueError("operation report version or operations is invalid")
        if not re.fullmatch(r"[0-9a-f]{64}", report.get("sourceDigest", "")):
            raise ValueError("operation report source digest is missing or invalid")
        expected: dict[str, str] = {}
        for operation in operations:
            operation_id = operation["id"]
            status = operation["status"]
            if not isinstance(operation_id, str) or not operation_id or operation_id in expected:
                raise ValueError("operation IDs must be nonempty and unique")
            if status not in labels:
                raise ValueError(f"unsupported operation status: {status}")
            if operation.get("screenId") not in known_screens:
                raise ValueError(f"unknown operation screen: {operation_id}")
            expected[operation_id] = status
        actual: dict[str, str] = {}
        actual_expectations: dict[str, str] = {}
        for operation_id, status, expectation in parser.operation_rows:
            if not operation_id or operation_id in actual:
                raise ValueError("HTML operation IDs must be nonempty and unique")
            actual[operation_id] = status
            actual_expectations[operation_id] = expectation
        if expected != actual:
            result.errors.append("Operation report and visible operation markers do not match.")
        expected_expectations = {operation["id"]: operation.get("expectedResult") or "" for operation in operations}
        if expected_expectations != actual_expectations:
            result.errors.append("Operation expectations do not match the embedded report.")
        expected_badges = [labels[operation["status"]] for operation in operations]
        if [badge.strip() for badge in parser.operation_badges] != expected_badges:
            result.errors.append("Operation status labels do not match the embedded report.")
        return len(expected)
    except (ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        result.errors.append(f"Invalid embedded operation report: {exc}")
        return 0


def validate_tailwind_profile(source: str, parser: WireframeParser, result: ValidationResult) -> int:
    """Tailwind profile: inline Tailwind CSS contract plus the embedded operation report. Returns the operation count."""
    _validate_tailwind_style(source, parser, result)
    return _validate_operation_report(parser, result)


PROFILE_VALIDATORS = {
    "pico": validate_pico_profile,
    "tailwind": validate_tailwind_profile,
}


def validate(path: Path, min_screens: int, require_actions: bool, profile: str | None = None) -> ValidationResult:
    result = ValidationResult(path)
    if profile is not None and profile not in PROFILE_VALIDATORS:
        result.errors.append(f"Unknown validation profile: {profile}")
        return result

    if not path.exists():
        result.errors.append(f"File does not exist: {path}")
        return result
    if not path.is_file():
        result.errors.append(f"Path is not a file: {path}")
        return result

    try:
        source = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        result.errors.append("File is not valid UTF-8 HTML.")
        return result

    validate_common_source(source, result)

    parser = WireframeParser()
    try:
        parser.feed(source)
    except Exception as exc:  # HTMLParser failures are uncommon but should be actionable.
        result.errors.append(f"HTML parsing failed: {exc}")
        return result

    selected_profile, profile_source = resolve_profile(parser, profile)

    validate_common(parser, result, min_screens, require_actions)
    operation_count = PROFILE_VALIDATORS[selected_profile](source, parser, result)
    validate_common_review_blocks(parser, result)
    validate_common_warnings(source, parser, result)

    result.details = {
        "screens": parser.screen_ids,
        "startScreen": parser.start_screens[0] if len(parser.start_screens) == 1 else None,
        "actionCount": len(parser.action_targets),
        "navigationCount": len(parser.nav_targets),
        "operationCount": operation_count,
        "inlineScripts": parser.inline_script_count,
        "picoVersion": parser.pico_version,
        "tailwindVersion": parser.tailwind_version,
        "profile": selected_profile,
        "profileSource": profile_source,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a self-contained interactive HTML wireframe."
    )
    parser.add_argument("html_file", type=Path, help="Path to the wireframe HTML file")
    parser.add_argument(
        "--min-screens", type=int, default=1, help="Minimum number of wireframe screens"
    )
    parser.add_argument(
        "--require-actions", action="store_true", help="Require at least one screen transition"
    )
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument(
        "--profile",
        choices=PROFILES,
        default=None,
        help="Style profile to enforce (pico or tailwind). Defaults to the profile the HTML declares.",
    )
    args = parser.parse_args()

    if args.min_screens < 1:
        print("ERROR: --min-screens must be at least 1.", file=sys.stderr)
        return 2

    result = validate(args.html_file, args.min_screens, args.require_actions, args.profile)

    if args.json:
        print(json.dumps(result.as_dict(), ensure_ascii=False, indent=2))
    else:
        if result.ok:
            print(
                f"SUCCESS: {args.html_file} satisfies the wireframe structure contract "
                f"({len(result.details.get('screens', []))} screens, "
                f"{result.details.get('actionCount', 0)} actions)."
            )
        else:
            print(f"FAILED: {args.html_file} has {len(result.errors)} validation error(s).", file=sys.stderr)
            for error in result.errors:
                print(f"- {error}", file=sys.stderr)
        for warning in result.warnings:
            print(f"WARNING: {warning}", file=sys.stderr)

    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
