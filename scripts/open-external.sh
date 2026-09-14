#!/bin/zsh
set -euo pipefail

# The manager writes this profile to ~/.codex/config_out.config.toml.
# Codex profile-v2 is selected with --profile, so keep the invocation explicit.
exec codex --profile config_out "$@"
