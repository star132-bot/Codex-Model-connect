---
name: codex-model-manager
description: Open the native model manager or delegate reasoning subtasks to configured Grok, Gemini, Claude, GPT-OSS, Antigravity, and other external models while keeping the current Codex GPT task and local tools.
---

# Codex Model Manager

The user's `~/.codex/config.toml` is always read-only for this plugin. Never edit it, add an external provider to it, replace its model catalog, or start the legacy local model router. External providers belong only in the model-manager state and `config_out.config.toml`.

## Open the native panel

When the user asks to open, launch, configure, add, edit, enable, disable, delete, test, or import a model, open the compact native panel.

macOS:

```bash
bash "${SKILL_DIR}/../../scripts/open-panel.sh"
```

Windows PowerShell:

```powershell
& "${SKILL_DIR}\..\..\scripts\open-panel.ps1"
```

`SKILL_DIR` is the directory containing this file. Resolve the script relative to this file when the host does not set it. After the command succeeds, tell the user the native panel is open. Do not ask for API keys in chat. The panel stores them in macOS Keychain or Windows Credential Manager.

## Delegate work to an external model

When the user asks Codex to give a task to another configured model, use `list_delegate_models` if the model is not already unambiguous, then call `delegate_task` with a concrete, self-contained subtask.

- The current Codex model remains the supervising GPT model and keeps all local tools.
- The external model receives only `task` and optional `context`; it does not automatically see local files, terminals, browsers, secrets, or conversation history.
- Supply only the minimum relevant file excerpts in `context`, never credentials.
- Treat the returned text as advice or a draft. Codex must inspect, verify, and apply it with its own tools.
- For large work, split it into bounded reasoning subtasks instead of sending the entire workspace.
- Omit `model` to use the panel's default delegate, or specify a provider name/model ID.

This is the supported way to use Grok, Gemini, Claude, GPT-OSS, and Antigravity inside an existing ChatGPT-account task. Do not tell the user to select an external model in the current task's model picker: Codex pins that task to the ChatGPT provider and the endpoint rejects the external model as unsupported.

The delegate supports OpenAI Responses, OpenAI Chat Completions, Gemini `generateContent`, and the locally authenticated Antigravity CLI. Antigravity login remains owned by `agy`; its credentials are never copied into Codex configuration.

After installing or updating the plugin, a newly created Codex task is required before the MCP tools appear. This refreshes plugin tool discovery; it does not switch the task to an external provider.
