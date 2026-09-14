#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
plugin_dir="${script_dir:h}"
app_path="$plugin_dir/dist/Codex Model Manager.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"

rm -rf "$app_path"
mkdir -p "$macos_path"

swiftc -O -parse-as-library \
  -framework SwiftUI \
  -framework Security \
  "$plugin_dir/native/LocalModelRouter.swift" \
  "$plugin_dir/native/CodexModelManager.swift" \
  -o "$macos_path/CodexModelManager"

cp "$plugin_dir/native/Info.plist" "$contents_path/Info.plist"
chmod 755 "$macos_path/CodexModelManager"
codesign --force --deep --sign - "$app_path" >/dev/null

echo "$app_path"
