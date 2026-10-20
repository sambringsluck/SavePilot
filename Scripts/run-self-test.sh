#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_binary="$(mktemp -d)/SavePilotSelfTest"

cd "$project_dir"
swiftc \
  Sources/SavePilot/Models.swift \
  Sources/SavePilot/AcademicSubjectClassifier.swift \
  Sources/SavePilot/FileNameSuggester.swift \
  Sources/SavePilot/MarkdownContentNormalizer.swift \
  Sources/SavePilot/AdvancedExtractors.swift \
  Sources/SavePilot/ContentExtractor.swift \
  Sources/SavePilot/EvidenceRanker.swift \
  Sources/SavePilot/FolderKnowledgeIndex.swift \
  Sources/SavePilot/FolderPathAutocomplete.swift \
  Sources/SavePilot/SeriesConsensus.swift \
  Sources/SavePilot/DocumentRelationshipEngine.swift \
  Sources/SavePilot/OllamaEmbeddingRetriever.swift \
  Sources/SavePilot/SuggestionEngine.swift \
  Sources/SavePilot/LearningStore.swift \
  Sources/SavePilot/FolderAuditEngine.swift \
  Sources/SavePilot/FileMover.swift \
  Sources/SavePilot/FolderMonitor.swift \
  Sources/SavePilot/UpdateChecker.swift \
  Scripts/self-test.swift \
  -o "$test_binary"
"$test_binary"
