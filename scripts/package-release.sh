#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
plugin_dir="${script_dir:h}"
release_dir="$plugin_dir/release"
mac_stage="$release_dir/macos"
windows_stage="$release_dir/windows-x64"

rm -rf "$release_dir"
mkdir -p "$mac_stage" "$windows_stage"

zsh "$script_dir/build-app.sh" >/dev/null
ditto "$plugin_dir/dist/Codex Model Manager.app" "$mac_stage/Codex Model Manager.app"
cp "$script_dir/install-macos.command" "$mac_stage/Install Codex Model Manager.command"
chmod 755 "$mac_stage/Install Codex Model Manager.command"
ditto -c -k --sequesterRsrc --keepParent "$mac_stage" "$release_dir/Codex-Model-Manager-macOS.zip"

if [[ -d "$plugin_dir/dist/windows-x64" ]]; then
  cp "$plugin_dir/dist/windows-x64/CodexModelManager.exe" "$windows_stage/"
  cp "$plugin_dir/windows/install.ps1" "$windows_stage/Install.ps1"
  cp "$plugin_dir/windows/uninstall.ps1" "$windows_stage/Uninstall.ps1"
  ditto -c -k --keepParent "$windows_stage" "$release_dir/Codex-Model-Manager-Windows-x64.zip"
fi

echo "$release_dir"
