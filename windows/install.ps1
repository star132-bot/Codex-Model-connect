$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "CodexModelManager.exe"
$targetDir = Join-Path $env:LOCALAPPDATA "CodexModelManager"
$target = Join-Path $targetDir "CodexModelManager.exe"

if (-not (Test-Path $source)) { throw "CodexModelManager.exe is missing from this package." }
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Get-Process CodexModelManager -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item -Force $source $target

$shell = New-Object -ComObject WScript.Shell
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Codex Model Manager.lnk"
$shortcut = $shell.CreateShortcut($startMenu)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $targetDir
$shortcut.Save()

Start-Process $target
Write-Host "Codex Model Manager installed for the current user." -ForegroundColor Green
