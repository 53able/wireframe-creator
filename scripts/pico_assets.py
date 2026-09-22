#!/usr/bin/env python3
"""Validate and render the vendored Pico CSS dependency contract."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


PICO_STYLE_OPEN_RE = re.compile(
    r"<style\b(?=[^>]*\bdata-pico-css\b)[^>]*>", re.IGNORECASE
)
PICO_STYLE_BLOCK_RE = re.compile(
    r"<style\b(?=[^>]*\bdata-pico-css\b)[^>]*>.*?</style\s*>",
    re.IGNORECASE | re.DOTALL,
)
WIREFRAME_STYLE_RE = re.compile(
    r"<style\b[^>]*\bdata-wireframe-style\b[^>]*>", re.IGNORECASE
)
HEAD_END_RE = re.compile(r"</head\s*>", re.IGNORECASE)


def skill_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _load_manifest() -> dict[str, object]:
    path = skill_root() / "assets" / "pico.manifest.json"
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise ValueError(f"Invalid Pico CSS manifest: {path}: {exc}") from exc
    required = {"version", "source", "css", "license"}
    if not isinstance(manifest, dict) or set(manifest) != required:
        raise ValueError("Pico CSS manifest must define version, source, css, and license.")
    version = manifest["version"]
    source = manifest["source"]
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Pico CSS manifest version must use semantic version form x.y.z.")
    if not isinstance(source, str) or source != f"https://github.com/picocss/pico/releases/tag/v{version}":
        raise ValueError("Pico CSS manifest source must be the matching official release URL.")
    for key in ("css", "license"):
        asset = manifest[key]
        if not isinstance(asset, dict) or set(asset) != {"path", "sha256"}:
            raise ValueError(f"Pico CSS manifest entry '{key}' must define path and sha256.")
        if not isinstance(asset["path"], str) or not re.fullmatch(
            r"[A-Za-z0-9._-]+", asset["path"]
        ):
            raise ValueError(f"Pico CSS manifest entry '{key}' has an invalid asset path.")
        if not isinstance(asset["sha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", asset["sha256"]
        ):
            raise ValueError(f"Pico CSS manifest entry '{key}' has an invalid SHA-256.")
    return manifest


PICO_MANIFEST = _load_manifest()
PICO_VERSION = str(PICO_MANIFEST["version"])
PICO_SOURCE = str(PICO_MANIFEST["source"])


def _read_verified_asset(kind: str) -> str:
    entry = PICO_MANIFEST[kind]
    if not isinstance(entry, dict):
        raise ValueError(f"Invalid Pico CSS manifest entry: {kind}")
    relative_path = str(entry["path"])
    if Path(relative_path).name != relative_path:
        raise ValueError(f"Pico CSS manifest path must be an asset filename: {relative_path}")
    path = skill_root() / "assets" / relative_path
    try:
        data = path.read_bytes()
    except FileNotFoundError as exc:
        raise ValueError(f"Vendored Pico CSS asset is missing: {path}") from exc
    actual = hashlib.sha256(data).hexdigest()
    expected = str(entry["sha256"])
    if actual != expected:
        raise ValueError(
            f"Vendored Pico CSS {kind} checksum mismatch: expected {expected}, found {actual}."
        )
    try:
        return data.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise ValueError(f"Vendored Pico CSS {kind} is not valid UTF-8: {path}") from exc


def render_pico_style_content() -> str:
    css = _read_verified_asset("css")
    license_text = _read_verified_asset("license")
    notice = "\n".join(f" * {line}" if line else " *" for line in license_text.splitlines())
    return (
        "/*!\n"
        f" * Pico CSS v{PICO_VERSION}\n"
        f" * Source: {PICO_SOURCE}\n"
        " *\n"
        f"{notice}\n"
        " */\n"
        f"{css}"
    )


def render_pico_style() -> str:
    return (
        f'<style data-pico-css data-pico-version="{PICO_VERSION}">\n'
        f"{render_pico_style_content()}\n"
        "</style>"
    )


def validate_pico_style(source: str) -> None:
    openings = list(PICO_STYLE_OPEN_RE.finditer(source))
    blocks = list(PICO_STYLE_BLOCK_RE.finditer(source))
    if len(openings) != 1 or len(blocks) != 1:
        raise ValueError(
            "HTML must contain exactly one complete data-pico-css style element; "
            f"found {len(openings)} opening tag(s) and {len(blocks)} complete block(s)."
        )
    if blocks[0].group(0) != render_pico_style():
        raise ValueError(
            f"Inline Pico CSS does not match the pinned v{PICO_VERSION} dependency contract. "
            "Use update-progress.py init --upgrade-pico for an explicit upgrade."
        )


def ensure_pico_style(source: str, *, upgrade: bool = False) -> str:
    openings = list(PICO_STYLE_OPEN_RE.finditer(source))
    blocks = list(PICO_STYLE_BLOCK_RE.finditer(source))
    if len(openings) > 1 or len(blocks) > 1:
        raise ValueError("HTML must contain at most one data-pico-css style element.")
    if openings and not blocks:
        raise ValueError("HTML contains an incomplete data-pico-css style element.")
    if blocks:
        if blocks[0].group(0) == render_pico_style():
            return source
        if not upgrade:
            validate_pico_style(source)
        return source[: blocks[0].start()] + render_pico_style() + source[blocks[0].end() :]

    wireframe_style = WIREFRAME_STYLE_RE.search(source)
    if wireframe_style:
        position = wireframe_style.start()
    else:
        head_end = HEAD_END_RE.search(source)
        if not head_end:
            raise ValueError("HTML must contain a closing </head> before Pico CSS can be embedded.")
        position = head_end.start()
    return source[:position] + render_pico_style() + "\n" + source[position:]
