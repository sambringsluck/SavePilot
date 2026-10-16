#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
binary="$(mktemp -d)/SavePilotFolderAuditReplay"
cd "$project_dir"
swiftc \
  Sources/SavePilot/Models.swift \
  Sources/SavePilot/AcademicSubjectClassifier.swift \
  Sources/SavePilot/MarkdownContentNormalizer.swift \
  Sources/SavePilot/AdvancedExtractors.swift \
  Sources/SavePilot/ContentExtractor.swift \
  Sources/SavePilot/FolderMonitor.swift \
  Sources/SavePilot/FolderAuditEngine.swift \
  Sources/SavePilot/DocumentRelationshipEngine.swift \
  Scripts/folder-audit-replay.swift \
  -o "$binary"
"$binary" "$@"
