#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 -m pip install --user "$project_dir[full]"
printf '%s\n' "Installed. Run: savepilot doctor"
printf '%s\n' "GUI: savepilot-gui --watch ~/Downloads --root ~/Documents"
printf '%s\n' "If ~/.local/bin is not on PATH, use: python3 -m savepilot.cli doctor"
