---
name: codex-model-manager
description: Open the native Codex Model Manager panel when the user asks to open, launch, configure, add, edit, enable, disable, delete, test, import, or switch custom Codex models or model providers.
---

# Codex Model Manager

Open the compact native panel with the command for the current operating system.

macOS:

```bash
bash "${SKILL_DIR}/../../scripts/open-panel.sh"
```

Windows PowerShell:

```powershell
& "${SKILL_DIR}\..\..\scripts\open-panel.ps1"
```

`SKILL_DIR` is the directory containing this `SKILL.md`. If it is not provided by the host, resolve the script relative to this file's absolute path.

After the command succeeds, tell the user the panel is open. Do not ask for API keys in chat. The panel stores keys in macOS Keychain or Windows Credential Manager. Successfully unlocked keys are cached only in the panel/router process memory, so switching models does not repeatedly request system authorization. By default it writes verified, enabled Responses-compatible providers to the separate user profile `~/.codex/config_out.config.toml`; the local GPT `~/.codex/config.toml` is left clean.

If the user asks why a Chat Completions or Gemini-native model cannot be activated, explain that Codex custom providers currently require the Responses API wire protocol. The panel can test those protocols, but deliberately blocks importing them as Codex main models.

The panel has two explicit modes:

- `隔离配置` (default): use the external models with `codex --profile config_out` (CLI/TUI). Current Codex Desktop does not pass profiles to its app-server, so this mode does not change the Desktop model picker.
- `桌面菜单兼容`: keep a local router and merged catalog so verified external models can appear beside GPT in Desktop. This is an opt-in compatibility mode and necessarily makes the Desktop menu a mixed list.

Codex pins the model provider when a task is created. An existing task created with the ChatGPT-account OpenAI provider cannot switch to Grok, Gemini, or another external provider even if that model later appears in the picker; the ChatGPT endpoint will reject it as unsupported. After enabling desktop compatibility and fully restarting Codex Desktop, create a new task and select the external model before sending its first message. Treat the panel's active selection as the default for new tasks, not as a hot switch for the current task.

The panel also includes an Antigravity account panel on both platforms. It can install the official `agy` CLI into the user account, open the CLI's Google sign-in flow, read `agy models`, show `/usage`, and test selected Gemini, Claude, or GPT-OSS models. “测试并导入 Codex” imports models that pass into desktop compatibility mode. The local router invokes `agy` and converts its JSON result into a streaming Responses response. Antigravity account sessions remain owned by `agy` and are not copied into Codex config or the manager credential store. This experimental bridge supports streamed text responses; Codex function/tool calling is unavailable because `agy` does not expose a reusable OpenAI function-calling protocol.
