# SavePilot Product Requirements Document

## 1. Product definition

SavePilot is a local-first file intelligence companion for macOS, Windows, and Linux. It analyzes completed files across common and uncommon formats, recommends a destination and—when the original name is weak—a better filename. The macOS edition can additionally observe supported Save/Save As panels. Every filesystem mutation requires explicit user confirmation.

The product optimizes for precision and recoverability, not for moving the largest possible number of files.

## 2. Core user problems

1. The user knows a document's meaning but not where it belongs in an evolving personal folder structure.
2. A broad category such as `学习` is technically correct but not useful when the user studies several subjects.
3. Names such as `hw3.pdf`, `scan001.pdf`, or `Untitled.docx` hide the document's meaning and later make classification and retrieval worse.
4. The user's preferred taxonomy is personal and changes over time; a fixed universal taxonomy cannot capture it.
5. Existing folders can contain historical mistakes, so the app must also audit a selected folder for topic outliers.

## 3. Product principles

- Human-in-the-loop: recommend, explain, and wait for confirmation.
- Precision first: abstain or keep the file in place when evidence is weak.
- Existing structure first: reuse coherent folders before proposing a new folder.
- Reusable granularity: prefer `物理` over `学习` for clear physics material, but never create a bespoke folder from one document title.
- Local first: extraction, OCR, folder profiles, user profile, and feedback memory remain on the user's device. Cloud models are opt-in refiners.
- Weak personal priors: user history may break a close tie but may not invent a subject unsupported by the current file.
- Reversible operations: collision-safe moves and undo; never overwrite.

## 4. Primary experience

### 4.1 Save-time preview

When a supported system Save/Save As panel is visible, SavePilot reads only the frontmost application name and proposed filename through macOS Accessibility. It presents a provisional destination and clearly labels that result as filename-only. Because the unsaved bytes still belong to the source app, content-aware naming is finalized after the write completes.

### 4.2 Content-aware review

After the file becomes stable on disk:

1. Extract text, structure, OCR, media metadata, archive inventory, or system metadata.
2. Resolve a specific subject or domain using title and body evidence.
3. Retrieve candidates from confirmed personal memory and the folder-content index.
4. Build file-to-file relations across organized and loose files; treat current directories as fallible labels.
5. Fuse filename, body topic, shared entities, graph/hyperedge links, directory labels, and format habits.
6. Apply the user-profile prior only when the current file already has multiple matching signals.
7. Recommend an existing folder, a reusable new folder, or abstention.
8. If the filename is low-information, propose an editable content-derived name while preserving the extension.
9. Move and/or rename only after confirmation.

A project-intent gate separates topical similarity from destination purpose. A mixed submission folder may contain copied references that resemble an incoming file; that resemblance is insufficient unless the folder has a coherent majority theme or the current file names the project anchor.

If the chosen candidate folder is itself under an incompatible parent, SavePilot does not discard a correct content match. It first creates a relocation prerequisite for the whole candidate folder and shows the planned final folder on dependent file suggestions. Those files pause until the folder decision is made; acceptance synchronizes its actual new path, while rejection returns them to the current folder path.

### 4.3 Folder audit

The user can select any folder. SavePilot builds a majority-topic profile, expands the sample when early files disagree, identifies strong file and child-folder outliers, and recommends alternative paths without changing the originals automatically. Parent-folder intent and child-folder content are scored separately so implementation artifacts do not mask a misplaced project.

## 5. Classification hierarchy

Academic content uses a two-level semantic hierarchy:

- Broad intent: `学习`
- Specific reusable subjects: `物理`, `数学`, `统计`, `经济学`, `计算机`, `化学`, `生物`, `历史`, `语言`

A specific subject wins only with sufficient current-file evidence and a clear margin over alternatives. Thus `AP Physics C`, force, mechanics, energy, and momentum route `hw3.pdf` to `物理`; an ambiguous worksheet that only says “complete questions 1–10” remains `学习` even if the user often studies physics.

The on-disk layout may use an existing personalized subject path or a new top-level subject folder. The semantic parent `学习` is explanatory and does not force an extra physical nesting level.

## 6. Personal user profile

The profile is derived progressively from:

- sampled content and names in organized folders;
- loose files observed on Desktop, Downloads, and selected watch roots;
- accepted destinations, path corrections, rejected suggestions, and accepted filename edits.

It records subject affinity and naming style, but it is never a substitute for current-file evidence. Folder profiles update incrementally as confirmed files arrive, so the profile is not frozen after onboarding. Users can rebuild the folder index and clear learned feedback.

## 7. Filename recommendations

- Trigger conservatively for generic, numeric, extremely short, or extremely long names.
- Use content fields such as subject, course, unit, document type, date, and assignment number.
- Preserve the original extension and sanitize path separators and control characters.
- Learn the user's accepted separator style after repeated edits.
- Show original and proposed names side by side in an editable field.
- Treat choosing the original name or editing the proposal as training feedback.
- Resolve collisions by adding a numeric suffix; never overwrite.

Example: `hw3.pdf` + “AP Physics C: Mechanics Homework #3” → `AP物理C_力学_作业3.pdf`.

## 8. Evaluation strategy

### 8.1 Deterministic Oracle corpus

`Scripts/oracle-eval.swift` generates development and untouched holdout cases for nine academic subjects plus adversarial non-academic files. The script reports accuracy, precision, recall, and confusion pairs, and fails the build when holdout quality falls below the declared gate.

`Training/hard_case_corpus.py` separately generates boundary-focused file-pair cases and can adapt the public 20-Newsgroups corpus into positives and nearby-category hard negatives. These cases test the file relationship graph rather than only broad subject labels.

This corpus is a regression oracle, not evidence of production accuracy and not model fine-tuning. Synthetic examples can expose deterministic regressions but cannot represent the user's full language, folder history, scans, or ambiguous real documents.

### 8.2 Real-file golden set

Maintain a private, local-only golden set of user-approved cases such as physics textbook, AP Physics homework, global history, economics competition, interview notes, financial Markdown, and intentional abstention. Record expected path, acceptable alternatives, expected rename, extraction quality, and latency. Never commit private file contents.

### 8.3 Metrics

- Destination precision among accepted recommendations
- Specific-subject precision and broad-category fallback rate
- New-folder precision and one-file-folder rate
- Filename proposal acceptance/edit/revert rate
- Rejection and undo rate
- Abstention accuracy
- Median and p95 time to first review
- Extraction success by file type

## 9. Acceptance criteria for 1.0

- Clear physics homework and textbooks prefer `物理` over `学习`.
- Ambiguous homework is not forced into the user's favorite subject.
- `hw3.pdf` receives an editable content-aware filename suggestion with `.pdf` preserved.
- A confirmed filename change is moved safely and undo restores the original path and name.
- Existing coherent folders beat new-folder creation when evidence is comparable.
- All recommendations remain independently selectable in the sidebar.
- Folder audits do not automatically move outliers.
- Synthetic holdout gates and self-tests pass in release builds.

## 10. Roadmap

- P1: richer date/course/instructor naming templates and a user-facing naming-style editor.
- P1: profile inspector with per-subject evidence, corrections, and opt-out controls.
- P1: export/import anonymized training events and a local golden-set runner.
- Delivered: optional local Ollama multilingual embedding retrieval, restricted to top-k candidate recall and evaluated behind the same abstention gates.
- Delivered: local Ollama top-candidate review with explicit model readiness diagnostics and safe fallback.
- P2: active learning that asks for labels only on high-value uncertain cases.
- P2: app-specific integrations where a source application exposes a supported automation or extension API.
- Delivered compatibility baseline: Python GUI/CLI, local indexing, polling monitor, OpenXML, optional PDF/OCR, and confirmation-safe moves on Windows/Linux/macOS.

## 11. Non-goals and platform limits

SavePilot does not inject unsupported controls into every application's save dialog, bypass macOS privacy permissions, organize managed photo/music libraries internally, or promise semantic extraction from encrypted or corrupt files. Custom save windows and cloud-only editors may only be observable after their exported file reaches a watched directory.
