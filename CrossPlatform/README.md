# SavePilot Cross-Platform

This directory contains both the installable Tauri desktop app and the Python classification engine used by Windows, Linux, and macOS. The desktop app bundles the engine, so end users do not need Python. The CLI and Tk window remain available for development and automation. The original Swift app remains the richest macOS build because OCR, Quick Look, PDFKit, Accessibility save-panel observation, and Apple models are platform APIs.

## Installable desktop app

Tagged releases are built on each operating system and published through GitHub Releases. The app includes first-run folder selection, a review queue, editable destinations and filenames, system notifications, launch-at-login, a tray icon, local capability checks, and confirmation-only moves.

To build it locally, install Node.js, current stable Rust, Python 3.10+, and the platform prerequisites listed by Tauri, then run:

```sh
python -m pip install . pyinstaller
python Desktop/scripts/build_sidecar.py
cd Desktop
npm ci
npm run tauri build
```

The generated installers are under `Desktop/src-tauri/target/release/bundle/`.

## Python GUI / CLI install

Linux:

```sh
sh installers/install-linux.sh
savepilot doctor
savepilot index --root ~/Documents
savepilot-gui --watch ~/Downloads --root ~/Documents
```

Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\installers\install-windows.ps1
savepilot doctor
savepilot index --root "$HOME\Documents"
savepilot-gui --watch "$HOME\Downloads" --root "$HOME\Documents"
```

Minimal install without PDF/OCR extras:

```sh
python -m pip install .
```

OCR additionally requires the Tesseract executable on `PATH`. On Linux, Tk may be packaged separately (for example `python3-tk`). Run `savepilot doctor` to see what is available.

## Commands

- `savepilot doctor`: compatibility and optional dependency check.
- `savepilot index --root PATH`: build a local folder-content index.
- `savepilot analyze FILE --root PATH`: read-only JSON/text recommendation.
- `savepilot analyze FILE --root PATH --interactive`: allow one confirmed move or rename.
- `savepilot watch --watch PATH --root PATH`: watch new files and ask in the console before every change.
- `savepilot-gui --watch PATH --root PATH`: desktop review queue. The filename editor is hidden when no rename is recommended.

The cross-platform build uses OpenXML parsing, optional PDF extraction and Tesseract OCR, subject hierarchy, TF-IDF-style folder profiles, majority-theme coherence, contrastive winner margins, and project-intent gates. It never overwrites a file and never moves anything without confirmation.

## Platform boundary

There is no universal, supported Windows/Linux/macOS API that injects controls into every application's Save As dialog. The portable build watches the directories where applications export files. App-specific save-dialog integrations can be added separately where the OS or source application exposes a supported extension API.
