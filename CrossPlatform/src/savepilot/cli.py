from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import sys
import time
from dataclasses import asdict
from pathlib import Path

from . import __version__
from .core import (
    confirm_move,
    data_directory,
    discover_profiles,
    load_profiles,
    recommend,
    save_profiles,
)


def _paths(values: list[str] | None) -> list[Path]:
    return [Path(value).expanduser().resolve() for value in (values or [])]


def _print_suggestion(suggestion, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps(asdict(suggestion), ensure_ascii=False, indent=2))
        return
    print(f"文件: {suggestion.source}")
    print(f"推荐目录: {suggestion.destination}{'（将新建）' if suggestion.creates_folder else ''}")
    if suggestion.changes_name:
        print(f"推荐文件名: {suggestion.proposed_file_name}")
    print(f"置信度: {suggestion.confidence:.0%}")
    print(f"原因: {suggestion.reason}")


def _interactive_confirm(suggestion) -> None:
    answer = input("确认存放？[y]确认 [e]编辑 [s]跳过: ").strip().lower()
    if answer not in {"y", "yes", "e", "edit"}:
        print("已跳过，文件未改变。")
        return
    folder = Path(suggestion.destination)
    name = suggestion.proposed_file_name
    if answer in {"e", "edit"}:
        raw_folder = input(f"目标目录 [{folder}]: ").strip()
        raw_name = input(f"文件名 [{name}]: ").strip()
        if raw_folder: folder = Path(raw_folder).expanduser()
        if raw_name: name = raw_name
    moved = confirm_move(suggestion, folder, name)
    print(f"已存放: {moved}")


def command_doctor(_: argparse.Namespace) -> int:
    checks = {
        "Python": sys.version.split()[0],
        "platform": sys.platform,
        "data directory": str(data_directory()),
        "Tk GUI": "available" if importlib.util.find_spec("tkinter") else "missing",
        "PDF text (pypdf)": "available" if importlib.util.find_spec("pypdf") else "optional dependency missing",
        "OCR (Pillow + pytesseract + Tesseract)": "available" if importlib.util.find_spec("PIL") and importlib.util.find_spec("pytesseract") and shutil.which("tesseract") else "optional dependency or Tesseract executable missing",
    }
    print(f"SavePilot {__version__}")
    for name, value in checks.items(): print(f"- {name}: {value}")
    return 0


def command_index(args: argparse.Namespace) -> int:
    roots = _paths(args.root)
    if not roots:
        raise SystemExit("index requires at least one --root")
    profiles = discover_profiles(roots)
    target = save_profiles(profiles)
    print(f"indexed {len(profiles)} folders -> {target}")
    return 0


def command_analyze(args: argparse.Namespace) -> int:
    roots = _paths(args.root)
    if not roots:
        roots = [Path(args.file).expanduser().resolve().parent]
    profiles = load_profiles()
    suggestion = recommend(Path(args.file), roots, profiles or None)
    _print_suggestion(suggestion, args.json)
    if args.interactive and not args.json:
        _interactive_confirm(suggestion)
    return 0


def _snapshot(folders: list[Path]) -> dict[Path, tuple[int, int]]:
    result: dict[Path, tuple[int, int]] = {}
    for folder in folders:
        try:
            for item in folder.iterdir():
                if item.is_file() and not item.name.startswith("."):
                    stat = item.stat()
                    result[item] = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            continue
    return result


def command_watch(args: argparse.Namespace) -> int:
    watched = _paths(args.watch)
    roots = _paths(args.root)
    if not watched or not roots:
        raise SystemExit("watch requires --watch and --root")
    profiles = load_profiles() or discover_profiles(roots)
    previous = {} if args.existing else _snapshot(watched)
    print("SavePilot is watching. Files are never moved without a console confirmation. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(max(0.5, args.interval))
            current = _snapshot(watched)
            changed = [path for path, stamp in current.items() if previous.get(path) != stamp]
            time.sleep(0.7)
            stable = _snapshot(watched)
            for path in changed:
                if path not in stable or stable[path] != current[path]: continue
                suggestion = recommend(path, roots, profiles)
                print()
                _print_suggestion(suggestion)
                _interactive_confirm(suggestion)
            previous = stable
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="savepilot", description="Cross-platform SavePilot")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)
    doctor = sub.add_parser("doctor", help="check optional extraction and UI capabilities")
    doctor.set_defaults(func=command_doctor)
    index = sub.add_parser("index", help="build a local folder-content index")
    index.add_argument("--root", action="append", required=True)
    index.set_defaults(func=command_index)
    analyze = sub.add_parser("analyze", help="analyze one file without moving it")
    analyze.add_argument("file")
    analyze.add_argument("--root", action="append")
    analyze.add_argument("--json", action="store_true")
    analyze.add_argument("--interactive", action="store_true", help="ask before moving/renaming")
    analyze.set_defaults(func=command_analyze)
    watch = sub.add_parser("watch", help="poll folders and ask before every move")
    watch.add_argument("--watch", action="append", required=True)
    watch.add_argument("--root", action="append", required=True)
    watch.add_argument("--interval", type=float, default=1.5)
    watch.add_argument("--existing", action="store_true")
    watch.set_defaults(func=command_watch)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
