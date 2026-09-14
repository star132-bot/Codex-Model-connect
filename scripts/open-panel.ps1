$ErrorActionPreference = "Stop"
$candidates = @(
  (Join-Path $env:LOCALAPPDATA "CodexModelManager\CodexModelManager.exe"),
  (Join-Path $PSScriptRoot "..\windows\bin\Release\net8.0-windows\CodexModelManager.exe")
)
$app = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $app) { throw "Codex Model Manager is not installed. Download the Windows release and run Install.ps1." }
Start-Process $app
