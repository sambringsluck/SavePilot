#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
replay_binary="$(mktemp -d)/SavePilotKnowledgeReplay"

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
  Scripts/knowledge-replay.swift \
  -o "$replay_binary"
"$replay_binary" "$@"
