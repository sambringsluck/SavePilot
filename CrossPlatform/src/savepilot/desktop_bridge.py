from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sys
import urllib.error
import urllib.request
from dataclasses import asdict
from pathlib import Path

from . import __version__
from .core import (
    Suggestion,
    confirm_move,
    data_directory,
    discover_profiles,
    extract,
    load_profiles,
    recommend,
    save_profiles,
)


def _roots(values: list[str]) -> list[Path]:
    return [Path(value).expanduser().resolve() for value in values]


def _write(payload: object) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def _profiles_for_roots(roots: list[Path]):
    cached = []
    for profile in load_profiles():
        profile_path = Path(profile.path)
        if any(profile_path == root or root in profile_path.parents for root in roots):
            cached.append(profile)
    return cached or discover_profiles(roots)


def _suggestion_payload(path: Path, roots: list[Path], profiles=None) -> dict[str, object]:
    profiles = profiles if profiles is not None else _profiles_for_roots(roots)
    suggestion = recommend(path, roots, profiles)
    content = extract(path)
    actionable = (
        Path(suggestion.destination).resolve() != path.parent.resolve()
        or suggestion.proposed_file_name.casefold() != path.name.casefold()
    )
    return {
        **asdict(suggestion),
        "summary": content.summary,
        "signals": content.signals,
        "changes_name": suggestion.changes_name,
        "actionable": actionable,
    }


def command_analyze(args: argparse.Namespace) -> int:
    path = Path(args.file).expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(path)
    _write(_suggestion_payload(path, _roots(args.root)))
    return 0


def command_scan(args: argparse.Namespace) -> int:
    roots = _roots(args.root)
    profiles = _profiles_for_roots(roots)
    candidates: list[Path] = []
    for watched in _roots(args.watch):
        try:
            candidates.extend(
                item for item in watched.iterdir()
                if item.is_file() and not item.name.startswith(".")
            )
        except OSError:
            continue
    def modified_at(item: Path) -> int:
        try:
            return item.stat().st_mtime_ns
        except OSError:
            return 0

    candidates.sort(key=modified_at, reverse=True)
    payload = []
    for path in candidates[: max(1, args.limit)]:
        try:
            suggestion = _suggestion_payload(path, roots, profiles)
            if suggestion["actionable"]:
                payload.append(suggestion)
        except OSError:
            continue
    _write(payload)
    return 0


def command_confirm(args: argparse.Namespace) -> int:
    source = Path(args.source).expanduser().resolve()
    suggestion = Suggestion(
        source=str(source),
        destination=str(Path(args.destination).expanduser().resolve()),
        proposed_file_name=args.name,
        reason="由用户在桌面应用中确认",
        confidence=1.0,
        creates_folder=not Path(args.destination).expanduser().exists(),
    )
    target = confirm_move(suggestion, Path(args.destination), args.name)
    _write({"destination": str(target)})
    return 0


def _ollama_status() -> dict[str, object]:
    request = urllib.request.Request("http://127.0.0.1:11434/api/tags")
    try:
        with urllib.request.urlopen(request, timeout=0.8) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return {
            "available": True,
            "models": [item.get("name", "") for item in payload.get("models", [])],
        }
    except (OSError, urllib.error.URLError, ValueError):
        return {"available": False, "models": []}


def command_doctor(_: argparse.Namespace) -> int:
    _write({
        "version": __version__,
        "python": sys.version.split()[0],
        "data_directory": str(data_directory()),
        "pdf": importlib.util.find_spec("pypdf") is not None,
        "ocr": bool(
            importlib.util.find_spec("PIL")
            and importlib.util.find_spec("pytesseract")
            and shutil.which("tesseract")
        ),
        "ollama": _ollama_status(),
    })
    return 0


def command_index(args: argparse.Namespace) -> int:
    profiles = discover_profiles(_roots(args.root))
    target = save_profiles(profiles)
    _write({"folders": len(profiles), "index": str(target)})
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="savepilot-engine")
    sub = parser.add_subparsers(dest="command", required=True)

    analyze = sub.add_parser("analyze")
    analyze.add_argument("--file", required=True)
    analyze.add_argument("--root", action="append", required=True)
    analyze.set_defaults(func=command_analyze)

    scan = sub.add_parser("scan")
    scan.add_argument("--watch", action="append", required=True)
    scan.add_argument("--root", action="append", required=True)
    scan.add_argument("--limit", type=int, default=100)
    scan.set_defaults(func=command_scan)

    confirm = sub.add_parser("confirm")
    confirm.add_argument("--source", required=True)
    confirm.add_argument("--destination", required=True)
    confirm.add_argument("--name", required=True)
    confirm.set_defaults(func=command_confirm)

    doctor = sub.add_parser("doctor")
    doctor.set_defaults(func=command_doctor)

    index = sub.add_parser("index")
    index.add_argument("--root", action="append", required=True)
    index.set_defaults(func=command_index)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        return int(args.func(args))
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
