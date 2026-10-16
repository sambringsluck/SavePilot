#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
binary="$(mktemp -d)/SavePilotOracleV2Eval"

cd "$project_dir"
swiftc \
  Sources/SavePilot/Models.swift \
  Sources/SavePilot/AcademicSubjectClassifier.swift \
  Sources/SavePilot/MarkdownContentNormalizer.swift \
  Sources/SavePilot/AdvancedExtractors.swift \
  Sources/SavePilot/ContentExtractor.swift \
  Sources/SavePilot/FolderMonitor.swift \
  Sources/SavePilot/EvidenceRanker.swift \
  Sources/SavePilot/FolderKnowledgeIndex.swift \
  Sources/SavePilot/DocumentRelationshipEngine.swift \
  Scripts/oracle-v2-eval.swift \
  -o "$binary"
"$binary" "$@"
