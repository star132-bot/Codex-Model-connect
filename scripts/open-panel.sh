#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
plugin_dir="$(cd -- "$script_dir/.." && pwd)"
app_path="$plugin_dir/dist/Codex Model Manager.app"
app_binary="$app_path/Contents/MacOS/CodexModelManager"

if [[ ! -x "$app_binary" || "$plugin_dir/native/CodexModelManager.swift" -nt "$app_binary" || "$plugin_dir/native/LocalModelRouter.swift" -nt "$app_binary" ]]; then
  "$script_dir/build-app.sh"
fi

open "$app_path"
