# SavePilot Cross-Platform

This package brings SavePilot's local, confirmation-first workflow to Windows, Linux, and macOS with Python 3.10+. It includes a CLI, polling watcher, folder-content index, and Tk review window. The original Swift app remains the richest macOS build because OCR, Quick Look, PDFKit, Accessibility save-panel observation, and Apple models are platform APIs.

## Install

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
