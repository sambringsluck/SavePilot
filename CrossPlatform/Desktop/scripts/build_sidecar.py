from __future__ import annotations

import shutil
import subprocess
import sys
import platform
from pathlib import Path


def main() -> int:
    desktop = Path(__file__).resolve().parents[1]
    cross_platform = desktop.parent
    output = desktop / "src-tauri" / "binaries"
    work = desktop / ".sidecar-build"
    output.mkdir(parents=True, exist_ok=True)
    try:
        target = subprocess.check_output(["rustc", "--print", "host-tuple"], text=True).strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        machine = platform.machine().lower()
        if sys.platform == "darwin":
            target = f"{'aarch64' if machine in {'arm64', 'aarch64'} else 'x86_64'}-apple-darwin"
        elif sys.platform == "win32":
            target = f"{'aarch64' if machine in {'arm64', 'aarch64'} else 'x86_64'}-pc-windows-msvc"
        elif sys.platform.startswith("linux"):
            target = f"{'aarch64' if machine in {'arm64', 'aarch64'} else 'x86_64'}-unknown-linux-gnu"
        else:
            raise RuntimeError(f"Unsupported sidecar target: {sys.platform}/{machine}")
    extension = ".exe" if sys.platform == "win32" else ""
    name = f"savepilot-engine-{target}{extension}"
    subprocess.run(
        [
            sys.executable, "-m", "PyInstaller",
            "--clean", "--noconfirm", "--onefile",
            "--name", "savepilot-engine",
            "--distpath", str(work / "dist"),
            "--workpath", str(work / "work"),
            "--specpath", str(work),
            "--paths", str(cross_platform / "src"),
            str(cross_platform / "engine_entry.py"),
        ],
        check=True,
        cwd=cross_platform,
    )
    source = work / "dist" / f"savepilot-engine{extension}"
    target_path = output / name
    shutil.copy2(source, target_path)
    target_path.chmod(0o755)
    print(target_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
