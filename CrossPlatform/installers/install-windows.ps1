$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
py -m pip install --user "${ProjectDir}[full]"
Write-Host "Installed. Run: savepilot doctor"
Write-Host 'GUI: savepilot-gui --watch "$HOME\Downloads" --root "$HOME\Documents"'
Write-Host "If the Python Scripts directory is not on PATH, use: py -m savepilot.cli doctor"
