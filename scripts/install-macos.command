#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_app="$script_dir/Codex Model Manager.app"
target_dir="$HOME/Applications"
target_app="$target_dir/Codex Model Manager.app"

if [[ ! -d "$source_app" ]]; then
  echo "Codex Model Manager.app is missing from this package."
  read -k 1
  exit 1
fi

mkdir -p "$target_dir"
ditto "$source_app" "$target_app"
open "$target_app"
echo "Installed to $target_app"
