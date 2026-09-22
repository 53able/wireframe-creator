#!/usr/bin/env python3
"""Create a working wireframe template with vendored Pico CSS embedded."""

from __future__ import annotations

import argparse
import os
import stat
import tempfile
from pathlib import Path

from pico_assets import render_pico_style, skill_root


def atomic_create(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, stat.S_IMODE(0o644))
        try:
            os.link(temporary, path)
        except FileExistsError as exc:
            raise ValueError(f"Refusing to overwrite existing output: {path}") from exc
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    template = (skill_root() / "assets" / "wireframe.template.html").read_text(
        encoding="utf-8"
    )
    if template.count("{{PICO_STYLE}}") != 1:
        raise ValueError("Wireframe template must contain exactly one {{PICO_STYLE}} token.")
    rendered = template.replace("{{PICO_STYLE}}", render_pico_style())
    atomic_create(args.output, rendered)
    print(f"SUCCESS: Wrote Pico CSS wireframe template to {args.output}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
