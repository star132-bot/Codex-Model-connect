$ErrorActionPreference = "Stop"
$targetDir = Join-Path $env:LOCALAPPDATA "CodexModelManager"
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Codex Model Manager.lnk"
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "CodexModelManagerRouter" -ErrorAction SilentlyContinue
Remove-Item -Force $startMenu -ErrorAction SilentlyContinue
Get-Process CodexModelManager -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force $targetDir -ErrorAction SilentlyContinue
Write-Host "Codex Model Manager removed. Saved providers and credentials were kept." -ForegroundColor Green
