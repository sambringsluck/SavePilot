#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir/CrossPlatform"
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m compileall -q src
