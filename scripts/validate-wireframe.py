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

from pico_assets import PICO_VERSION


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
        self.pico_style_count = 0
        self.pico_version: str | None = None
        self.in_pico_style = False
        self.pico_style_parts: list[str] = []
        self.assumptions_blocks = 0
        self.open_question_blocks = 0
        self.current_screen: str | None = None
        self.screen_heading_count: dict[str, int] = {}
        self.screen_aria_labelled: set[str] = set()
        self._screen_stack: list[str | None] = []

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
            if values.get("src"):
                self.external_script_count += 1
            else:
                self.inline_script_count += 1
        if tag == "link" and "stylesheet" in values.get("rel", "").lower():
            self.stylesheet_links += 1
        if tag == "style" and "data-pico-css" in values:
            self.pico_style_count += 1
            self.pico_version = values.get("data-pico-version") or None
            self.in_pico_style = True

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
        if "data-assumptions" in values:
            self.assumptions_blocks += 1
        if "data-open-questions" in values:
            self.open_question_blocks += 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False
        if tag == "style" and self.in_pico_style:
            self.in_pico_style = False
        if tag not in VOID_TAGS and self._screen_stack:
            self.current_screen = self._screen_stack.pop()

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)
        if self.in_pico_style:
            self.pico_style_parts.append(data)


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


def validate(path: Path, min_screens: int, require_actions: bool) -> ValidationResult:
    result = ValidationResult(path)

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

    if not re.match(r"\s*<!doctype\s+html", source, re.IGNORECASE):
        result.errors.append("Missing <!doctype html> declaration.")

    placeholders = sorted(set(PLACEHOLDER_RE.findall(source)))
    if placeholders:
        result.errors.append(
            "Unresolved template placeholders remain: " + ", ".join(placeholders[:10])
        )

    parser = WireframeParser()
    try:
        parser.feed(source)
    except Exception as exc:  # HTMLParser failures are uncommon but should be actionable.
        result.errors.append(f"HTML parsing failed: {exc}")
        return result

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
    if parser.pico_style_count != 1:
        result.errors.append(
            f"Expected exactly one inline Pico CSS style; found {parser.pico_style_count}."
        )
    elif parser.pico_version != PICO_VERSION:
        result.errors.append(
            f"Expected Pico CSS version {PICO_VERSION}; found {parser.pico_version or 'none'}."
        )
    pico_style = "".join(parser.pico_style_parts)
    required_notice_parts = ("MIT License", "Copyright (c) 2019-2024 Pico", "Permission is hereby granted")
    missing_notice_parts = [part for part in required_notice_parts if part not in pico_style]
    if parser.pico_style_count == 1 and missing_notice_parts:
        result.errors.append("Inline Pico CSS is missing the complete MIT license notice.")
    if parser.assumptions_blocks == 0:
        result.errors.append("Missing an element with data-assumptions.")
    if parser.open_question_blocks == 0:
        result.errors.append("Missing an element with data-open-questions.")

    if not re.search(r":focus-visible|:focus\b", source):
        result.warnings.append("No explicit keyboard focus style was detected.")
    if not parser.inline_script_count and parser.action_targets:
        result.warnings.append("Transitions exist, but no inline script was detected to operate them.")

    result.details = {
        "screens": parser.screen_ids,
        "startScreen": parser.start_screens[0] if len(parser.start_screens) == 1 else None,
        "actionCount": len(parser.action_targets),
        "navigationCount": len(parser.nav_targets),
        "inlineScripts": parser.inline_script_count,
        "picoVersion": parser.pico_version,
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
    args = parser.parse_args()

    if args.min_screens < 1:
        print("ERROR: --min-screens must be at least 1.", file=sys.stderr)
        return 2

    result = validate(args.html_file, args.min_screens, args.require_actions)

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
