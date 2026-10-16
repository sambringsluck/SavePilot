#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
binary="$(mktemp -d)/SavePilotOracleEval"

cd "$project_dir"
swiftc \
  Sources/SavePilot/Models.swift \
  Sources/SavePilot/AcademicSubjectClassifier.swift \
  Scripts/oracle-eval.swift \
  -o "$binary"
"$binary" "$@"
