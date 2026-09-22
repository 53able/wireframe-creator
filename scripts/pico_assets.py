#!/usr/bin/env python3
"""Render the vendored Pico CSS with its required MIT notice."""

from __future__ import annotations

import re
from pathlib import Path


PICO_VERSION = "2.1.1"
PICO_SOURCE = f"https://github.com/picocss/pico/releases/tag/v{PICO_VERSION}"
PICO_STYLE_RE = re.compile(r"<style\b[^>]*\bdata-pico-css\b[^>]*>", re.IGNORECASE)
WIREFRAME_STYLE_RE = re.compile(
    r"<style\b[^>]*\bdata-wireframe-style\b[^>]*>", re.IGNORECASE
)
HEAD_END_RE = re.compile(r"</head\s*>", re.IGNORECASE)


def skill_root() -> Path:
    return Path(__file__).resolve().parent.parent


def render_pico_style() -> str:
    assets = skill_root() / "assets"
    css = (assets / "pico.min.css").read_text(encoding="utf-8").strip()
    license_text = (assets / "pico.LICENSE.md").read_text(encoding="utf-8").strip()
    notice = "\n".join(f" * {line}" if line else " *" for line in license_text.splitlines())
    return (
        f'<style data-pico-css data-pico-version="{PICO_VERSION}">\n'
        "/*!\n"
        f" * Pico CSS v{PICO_VERSION}\n"
        f" * Source: {PICO_SOURCE}\n"
        " *\n"
        f"{notice}\n"
        " */\n"
        f"{css}\n"
        "</style>"
    )


def ensure_pico_style(source: str) -> str:
    matches = list(PICO_STYLE_RE.finditer(source))
    if len(matches) > 1:
        raise ValueError("HTML must contain at most one data-pico-css style element.")
    if matches:
        return source

    wireframe_style = WIREFRAME_STYLE_RE.search(source)
    if wireframe_style:
        position = wireframe_style.start()
    else:
        head_end = HEAD_END_RE.search(source)
        if not head_end:
            raise ValueError("HTML must contain a closing </head> before Pico CSS can be embedded.")
        position = head_end.start()
    return source[:position] + render_pico_style() + "\n" + source[position:]
