#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/dist-cross-platform"
mkdir -p "$output_dir"
for old_wheel in "$output_dir"/savepilot-*.whl(N); do
  rm -- "$old_wheel"
done
cd "$project_dir/CrossPlatform"
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m pip wheel --no-deps --wheel-dir "$output_dir" .
cp README.md "$output_dir/README-Windows-Linux.md"
cp installers/install-linux.sh installers/install-windows.ps1 "$output_dir/"
ls -lh "$output_dir"
