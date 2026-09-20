#!/usr/bin/env python3
"""Add, update, stage, and remove temporary progress UI in wireframe HTML."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path


START_MARKER = "<!-- WIREFRAME_PROGRESS_START -->"
END_MARKER = "<!-- WIREFRAME_PROGRESS_END -->"
BLOCK_RE = re.compile(
    rf"{re.escape(START_MARKER)}.*?{re.escape(END_MARKER)}", re.DOTALL
)
STATE_RE = re.compile(
    r'<script type="application/json" data-generation-progress-state>(.*?)</script>',
    re.DOTALL,
)
BODY_RE = re.compile(r"(<body\b[^>]*>)", re.IGNORECASE)
DOCTYPE_RE = re.compile(r"^\s*<!doctype\s+html", re.IGNORECASE)

STEPS = [
    ("input", "入力と保存場所を確認"),
    ("brief", "検証目的と対象フローを定義"),
    ("design", "画面と状態を設計"),
    ("html-generation", "HTMLを生成または部分編集"),
    ("structural-validation", "構造検証"),
    ("browser-validation", "ブラウザ検証"),
    ("finalization", "最終化"),
]
STEP_LABELS = dict(STEPS)
VALID_STATES = {"pending", "running", "pass", "fail", "not-run"}
STATE_LABELS = {
    "pending": "未着手",
    "running": "実行中",
    "pass": "完了",
    "fail": "失敗",
    "not-run": "未実施",
}
VALID_MODES = {"wall", "new", "l0", "l1", "l2", "l3"}
ALLOWED_TRANSITIONS = {
    "pending": {"pending", "running", "not-run"},
    "running": {"running", "pass", "fail", "not-run"},
    "pass": {"pass", "running"},
    "fail": {"fail", "running", "not-run"},
    "not-run": {"not-run", "running"},
}


def skill_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ValueError(f"File does not exist: {path}") from exc
    except UnicodeDecodeError as exc:
        raise ValueError(f"File is not valid UTF-8: {path}") from exc


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing_mode: int | None = None
    if path.exists():
        existing_mode = stat.S_IMODE(path.stat().st_mode)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    temp_path = Path(handle.name)
    try:
        with handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if existing_mode is not None:
            os.chmod(temp_path, existing_mode)
        os.replace(temp_path, path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def validate_html_document(source: str, path: Path) -> None:
    if not DOCTYPE_RE.search(source):
        raise ValueError(f"HTML must start with <!doctype html>: {path}")
    if not BODY_RE.search(source):
        raise ValueError(f"HTML must contain a <body> element: {path}")
    if not re.search(r"</body\s*>", source, re.IGNORECASE):
        raise ValueError(f"HTML must contain a closing </body>: {path}")
    if not re.search(r"</html\s*>", source, re.IGNORECASE):
        raise ValueError(f"HTML must contain a closing </html>: {path}")


def validate_markers(source: str) -> bool:
    starts = source.count(START_MARKER)
    ends = source.count(END_MARKER)
    if starts == 0 and ends == 0:
        return False
    if starts != 1 or ends != 1:
        raise ValueError(
            f"Progress markers are malformed: found {starts} start marker(s) and {ends} end marker(s)."
        )
    match = BLOCK_RE.search(source)
    if not match:
        raise ValueError("Progress markers exist, but a complete progress block could not be parsed.")
    return True


def extract_block(source: str) -> str:
    validate_markers(source)
    match = BLOCK_RE.search(source)
    if not match:
        raise ValueError("Progress block is missing.")
    return match.group(0)


def strip_block(source: str) -> str:
    if not validate_markers(source):
        return source
    return BLOCK_RE.sub("", source, count=1)


def parse_state(block: str, *, upgrade_legacy: bool = False) -> dict[str, object]:
    match = STATE_RE.search(block)
    if not match:
        raise ValueError("Progress block is missing its machine-readable state.")
    try:
        state = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Progress state JSON is invalid: {exc}") from exc
    if not isinstance(state, dict):
        raise ValueError("Progress state JSON must be an object.")
    version = state.get("version")
    if version not in {1, 2}:
        raise ValueError(f"Unsupported progress state version: {version}")
    if version == 1:
        if not upgrade_legacy:
            raise ValueError(
                "Progress state version 1 requires explicit migration. Run init again with --upgrade."
            )
        state["version"] = 2
        state["startedAtEpochMs"] = time.time_ns() // 1_000_000
        state.pop("refreshMs", None)
    started_at = state.get("startedAtEpochMs")
    if isinstance(started_at, bool) or not isinstance(started_at, int) or started_at < 0:
        raise ValueError("Progress state must contain a non-negative integer startedAtEpochMs.")
    if state.get("mode") not in VALID_MODES:
        raise ValueError(f"Progress state contains an invalid mode: {state.get('mode')}")
    for field in ("title", "message"):
        if not isinstance(state.get(field), str):
            raise ValueError(f"Progress state field '{field}' must be a string.")
    steps = state.get("steps")
    if not isinstance(steps, list) or not all(isinstance(item, dict) for item in steps):
        raise ValueError("Progress state steps must be a list of objects.")
    step_ids = [item.get("id") for item in steps]
    if step_ids != [step_id for step_id, _ in STEPS]:
        raise ValueError("Progress state does not contain the expected ordered step IDs.")
    for item, (_, expected_label) in zip(steps, STEPS):
        if item.get("label") != expected_label:
            raise ValueError(f"Invalid stored label for {item.get('id')}: {item.get('label')}")
        if item.get("state") not in VALID_STATES:
            raise ValueError(f"Invalid stored state for {item.get('id')}: {item.get('state')}")
    return state


def overall_status(state: dict[str, object]) -> str:
    states = [item["state"] for item in state["steps"]]
    if "fail" in states:
        return "failed"
    if all(value in {"pass", "not-run"} for value in states):
        return "complete"
    return "running"


def json_for_script(state: dict[str, object]) -> str:
    return json.dumps(state, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


def render_block(state: dict[str, object]) -> str:
    template_path = skill_root() / "assets" / "progress-panel.fragment.html"
    client_path = skill_root() / "assets" / "hot-reload-client.fragment.html"
    template = read_text(template_path)
    hot_reload_client = read_text(client_path).rstrip()
    items = []
    for item in state["steps"]:
        items.append(
            "    <li data-progress-step=\"{}\" data-state=\"{}\" aria-label=\"{}: {}\">{}</li>".format(
                html.escape(str(item["id"]), quote=True),
                html.escape(str(item["state"]), quote=True),
                html.escape(str(item["label"]), quote=True),
                html.escape(STATE_LABELS[str(item["state"])], quote=True),
                html.escape(str(item["label"])),
            )
        )
    replacements = {
        "{{PROGRESS_STATUS}}": overall_status(state),
        "{{PROGRESS_TITLE}}": html.escape(str(state["title"])),
        "{{PROGRESS_MESSAGE}}": html.escape(str(state["message"])),
        "{{PROGRESS_STEPS}}": "\n".join(items),
        "{{PROGRESS_STATE_JSON}}": json_for_script(state),
        "{{HOT_RELOAD_CLIENT}}": hot_reload_client,
    }
    rendered = template
    for token, value in replacements.items():
        rendered = rendered.replace(token, value)
    unresolved = sorted(set(re.findall(r"\{\{[^{}]+\}\}", rendered)))
    if unresolved:
        raise ValueError("Progress template has unresolved placeholders: " + ", ".join(unresolved))
    return rendered.rstrip()


def initial_state(mode: str, title: str) -> dict[str, object]:
    return {
        "version": 2,
        "mode": mode,
        "title": f"{title}を作成中",
        "message": "入力と保存場所を確認しています",
        "startedAtEpochMs": time.time_ns() // 1_000_000,
        "steps": [
            {"id": step_id, "label": label, "state": "running" if step_id == "input" else "pending"}
            for step_id, label in STEPS
        ],
    }


def inject_after_body(source: str, block: str, path: Path) -> str:
    validate_html_document(source, path)
    if validate_markers(source):
        raise ValueError(f"HTML already contains a progress block: {path}")
    match = BODY_RE.search(source)
    if not match:
        raise ValueError(f"HTML must contain a <body> element: {path}")
    return source[: match.end()] + block + source[match.end() :]


def command_init(args: argparse.Namespace) -> None:
    path: Path = args.html
    if args.mode not in VALID_MODES:
        raise ValueError(f"Unknown mode '{args.mode}'. Choose from: {', '.join(sorted(VALID_MODES))}")
    if path.exists():
        source = read_text(path)
        validate_html_document(source, path)
        if validate_markers(source):
            old_block = extract_block(source)
            state = parse_state(old_block, upgrade_legacy=args.upgrade)
            new_block = render_block(state)
            if old_block != new_block:
                output = BLOCK_RE.sub(lambda _: new_block, source, count=1)
                atomic_write(path, output)
                print(f"SUCCESS: Upgraded existing progress UI in {path} without resetting its workflow state.")
            else:
                print(f"SUCCESS: Progress is already initialized in {path}; no duplicate was added.")
            return
        title = args.title or path.stem
        output = inject_after_body(source, render_block(initial_state(args.mode, title)), path)
    else:
        title = args.title or path.stem
        shell_path = skill_root() / "assets" / "progress-shell.template.html"
        shell = read_text(shell_path)
        output = shell.replace("{{TITLE}}", html.escape(title)).replace(
            "{{PROGRESS_BLOCK}}", render_block(initial_state(args.mode, title))
        )
        if re.search(r"\{\{[^{}]+\}\}", output):
            raise ValueError("Progress shell has unresolved placeholders.")
        validate_html_document(output, path)
    atomic_write(path, output)
    print(f"SUCCESS: Initialized temporary progress UI in {path}.")


def command_set(args: argparse.Namespace) -> None:
    path: Path = args.html
    source = read_text(path)
    block = extract_block(source)
    state = parse_state(block)
    if args.step not in STEP_LABELS:
        raise ValueError(f"Unknown step '{args.step}'. Choose from: {', '.join(STEP_LABELS)}")
    if args.state not in VALID_STATES:
        raise ValueError(f"Unknown state '{args.state}'. Choose from: {', '.join(sorted(VALID_STATES))}")
    if args.state in {"fail", "not-run"} and not args.message:
        raise ValueError(f"--message is required when state is '{args.state}'.")
    step = next(item for item in state["steps"] if item["id"] == args.step)
    previous = str(step["state"])
    if args.state not in ALLOWED_TRANSITIONS[previous]:
        raise ValueError(f"Invalid transition for {args.step}: {previous} -> {args.state}.")
    if args.state == "running":
        other_running = [
            item["id"] for item in state["steps"] if item["id"] != args.step and item["state"] == "running"
        ]
        if other_running:
            raise ValueError(
                "Another step is already running: " + ", ".join(other_running) + ". Complete or fail it first."
            )
        step_index = [item["id"] for item in state["steps"]].index(args.step)
        blockers = [
            item["id"]
            for item in state["steps"][:step_index]
            if item["state"] not in {"pass", "not-run"}
        ]
        if blockers:
            raise ValueError(
                "Earlier steps must be pass or not-run before starting "
                + args.step
                + ": "
                + ", ".join(blockers)
            )
    step["state"] = args.state
    if args.message:
        state["message"] = args.message
    elif args.state == "running":
        state["message"] = f"{step['label']}を実行しています"
    elif args.state == "pass":
        state["message"] = f"{step['label']}が完了しました"
    new_block = render_block(state)
    output = BLOCK_RE.sub(lambda _: new_block, source, count=1)
    if strip_block(source) != strip_block(output):
        raise ValueError("Progress update would modify content outside the progress block; update aborted.")
    atomic_write(path, output)
    print(f"SUCCESS: Updated {args.step} from {previous} to {args.state} in {path}.")


def command_fail(args: argparse.Namespace) -> None:
    args.state = "fail"
    command_set(args)


def command_prepare(args: argparse.Namespace) -> None:
    source_path: Path = args.html
    destination: Path = args.destination
    if source_path.resolve() == destination.resolve():
        raise ValueError("--destination must differ from the progress HTML path.")
    source = read_text(source_path)
    clean = strip_block(source)
    validate_html_document(clean, source_path)
    atomic_write(destination, clean)
    print(f"SUCCESS: Wrote a progress-free working copy to {destination}.")


def command_stage(args: argparse.Namespace) -> None:
    target: Path = args.html
    source_path: Path = args.source
    if target.resolve() == source_path.resolve():
        raise ValueError("--source must differ from the progress HTML path.")
    current = read_text(target)
    block = extract_block(current)
    parse_state(block)
    candidate = read_text(source_path)
    validate_html_document(candidate, source_path)
    if START_MARKER in candidate or END_MARKER in candidate or "data-generation-progress" in candidate:
        raise ValueError("The staged source must not contain a progress block or progress attributes.")
    output = inject_after_body(candidate, block, source_path)
    atomic_write(target, output)
    print(f"SUCCESS: Staged {source_path} into {target} while preserving progress state.")


def command_finalize(args: argparse.Namespace) -> None:
    path: Path = args.html
    source = read_text(path)
    if not validate_markers(source):
        command_verify_final(args)
        print(f"SUCCESS: {path} was already finalized.")
        return
    state = parse_state(extract_block(source))
    for item in state["steps"]:
        if item["id"] == "finalization":
            if item["state"] != "running":
                raise ValueError("Set the finalization step to running before finalize.")
        elif item["state"] not in {"pass", "not-run"}:
            raise ValueError(
                f"Cannot finalize while step '{item['id']}' is '{item['state']}'. Mark it pass or not-run first."
            )
    output = strip_block(source)
    validate_html_document(output, path)
    atomic_write(path, output)
    print(f"SUCCESS: Removed temporary progress UI from {path}.")


def command_verify_final(args: argparse.Namespace) -> None:
    path: Path = args.html
    source = read_text(path)
    validate_html_document(source, path)
    forbidden = [
        START_MARKER,
        END_MARKER,
        "data-generation-progress",
        "data-progress-step",
        "data-progress-message",
        "data-progress-elapsed",
        "data-progress-timing",
        "data-hot-reload-status",
        "data-reset-preview-state",
        "data-generation-progress-style",
        "data-wireframe-hot-reload",
        "__wireframeHotReload",
        "startedAtEpochMs",
        "refreshMs",
        "__wireframe/events",
        "__wireframe/document",
        "EventSource",
        "window.location.reload",
    ]
    found = [token for token in forbidden if token in source]
    if found:
        raise ValueError("Temporary progress content remains: " + ", ".join(found))
    print(f"SUCCESS: {path} contains no temporary progress UI.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage temporary progress UI and hot-reload metadata in wireframe HTML."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Create a progress shell or inject progress UI")
    init_parser.add_argument("html", type=Path)
    init_parser.add_argument("--mode", required=True, choices=sorted(VALID_MODES))
    init_parser.add_argument("--title")
    init_parser.add_argument(
        "--upgrade",
        action="store_true",
        help="Explicitly migrate an existing version 1 progress block to version 2",
    )
    init_parser.set_defaults(handler=command_init)

    set_parser = subparsers.add_parser("set", help="Update one progress step")
    set_parser.add_argument("html", type=Path)
    set_parser.add_argument("--step", required=True)
    set_parser.add_argument("--state", required=True)
    set_parser.add_argument("--message")
    set_parser.set_defaults(handler=command_set)

    fail_parser = subparsers.add_parser("fail", help="Mark one progress step as failed")
    fail_parser.add_argument("html", type=Path)
    fail_parser.add_argument("--step", required=True)
    fail_parser.add_argument("--message", required=True)
    fail_parser.set_defaults(handler=command_fail)

    prepare_parser = subparsers.add_parser("prepare", help="Create a progress-free working copy")
    prepare_parser.add_argument("html", type=Path)
    prepare_parser.add_argument("--destination", type=Path, required=True)
    prepare_parser.set_defaults(handler=command_prepare)

    stage_parser = subparsers.add_parser("stage", help="Stage working HTML while preserving progress")
    stage_parser.add_argument("html", type=Path)
    stage_parser.add_argument("--source", type=Path, required=True)
    stage_parser.set_defaults(handler=command_stage)

    finalize_parser = subparsers.add_parser("finalize", help="Remove temporary progress UI")
    finalize_parser.add_argument("html", type=Path)
    finalize_parser.set_defaults(handler=command_finalize)

    verify_parser = subparsers.add_parser("verify-final", help="Verify no progress UI remains")
    verify_parser.add_argument("html", type=Path)
    verify_parser.set_defaults(handler=command_verify_final)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
