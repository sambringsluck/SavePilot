# SavePilot portability architecture

## Supported deployment paths

| Platform | User interface | Monitoring | Content extraction | Save-panel integration |
|---|---|---|---|---|
| macOS 14+ | Native SwiftUI app | FSEvents | PDFKit, Vision OCR, OpenXML, Spotlight, Quick Look, AVFoundation | Accessibility preview + post-save verification |
| Windows 10/11 | Python Tk app or CLI | Portable stable-file polling | OpenXML, text, optional pypdf and Tesseract OCR | Post-save watched folders |
| Linux | Python Tk app or CLI | Portable stable-file polling | OpenXML, text, optional pypdf and Tesseract OCR | Post-save watched folders |

The decision policy is intentionally aligned across implementations: specific-subject hierarchy, low-information filename detection, majority-theme folder profiles, coherence gating, protected project intent, winner-margin abstention, confirmation-only moves, collision protection, and extension preservation.

## Why the UI integration differs

macOS Accessibility can observe many system save panels. Windows UI Automation and Linux AT-SPI do not provide one reliable, permission-safe extension that works across every native toolkit, browser, sandbox, and custom dialog. The portable build therefore watches explicit export directories. Per-application plugins can be layered on later without weakening the core safety model.

## Compatibility contract

- Python 3.10 or later; no required third-party runtime dependency for metadata, text, Markdown, and OpenXML.
- Optional `pypdf` for PDF text and Pillow + Tesseract for image OCR.
- Platform-correct local data directories (`APPDATA`, XDG data home, or macOS Application Support).
- `pathlib` paths, Unicode filenames, extension-preserving renames, and collision-safe moves.
- No automatic filesystem mutation. CLI and GUI both require a user confirmation.
- A missing optional extractor degrades to metadata-level classification rather than failing the queue.

## Release validation

The repository runs Swift self-tests, synthetic Oracle tests, real-file knowledge replay on macOS, and dependency-free Python unit tests. The Python wheel is tagged `py3-none-any`, meaning it contains no platform-specific binary. A real Windows and Linux release should additionally run the same tests in GitHub Actions on `windows-latest` and `ubuntu-latest`; UI and OS packaging remain platform smoke tests rather than being inferred from macOS.
