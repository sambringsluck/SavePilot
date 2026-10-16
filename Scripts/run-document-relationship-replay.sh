#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
binary="$(mktemp -d)/SavePilotDocumentRelationshipReplay"
cd "$project_dir"
swiftc \
  Sources/SavePilot/Models.swift \
  Sources/SavePilot/MarkdownContentNormalizer.swift \
  Sources/SavePilot/AdvancedExtractors.swift \
  Sources/SavePilot/ContentExtractor.swift \
  Sources/SavePilot/FolderMonitor.swift \
  Sources/SavePilot/DocumentRelationshipEngine.swift \
  Scripts/document-relationship-replay.swift \
  -o "$binary"
"$binary" "$@"
