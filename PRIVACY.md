# Privacy

SavePilot is local-first. It reads only the folders selected by the user, plus the default Desktop, Downloads, and Documents locations described during first-run setup. It excludes macOS system libraries, application containers, managed media libraries, hidden folders, trash, and common development/build caches.

- File extraction, OCR, folder profiles, relationship graphs, feedback memory, and Ollama processing run locally.
- SavePilot has no analytics, advertising SDK, crash-upload service, or telemetry endpoint.
- Files are never moved, renamed, or used to create a folder without an explicit confirmation.
- DeepSeek is optional. When enabled, its API request contains the bounded fields described in Settings; the original file is not uploaded. The API key stays in macOS Keychain.
- Local profiles, feedback, and diagnostics are stored under `~/Library/Application Support/SavePilot` or app preferences. They can be removed by deleting that folder and the app's preferences.

The Accessibility permission is used only to recognize standard save panels and read a proposed filename/application name. SavePilot does not click Save, inspect password fields, or control the originating application.

For a vulnerability or privacy issue, follow [SECURITY.md](SECURITY.md).
