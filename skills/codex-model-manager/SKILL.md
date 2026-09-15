---
name: codex-model-manager
description: Open the native model manager or delegate reasoning subtasks to configured Grok, Gemini, Claude, GPT-OSS, Antigravity, and other external models while keeping the current Codex GPT task and local tools.
---

# Codex Model Manager

Ordinary provider management and delegation must not edit `~/.codex/config.toml` or `~/.codex/auth.json`. The native panel also has an explicit configuration-profile workflow. Only when the user clicks `一键切换` may it transactionally replace the complete `config.toml` and `auth.json` pair. It backs up the current config, keeps auth contents in the operating-system credential store, rolls both files back if either write fails, and requires a full Codex restart afterward. Never start the legacy local model router.

## Open the native panel

When the user asks to open, launch, configure, add, edit, enable, disable, delete, test, import a model, save a Codex login, or switch URL/API Key configurations, open the compact native panel.

macOS:

```bash
bash "${SKILL_DIR}/../../scripts/open-panel.sh"
```

Windows PowerShell:

```powershell
& "${SKILL_DIR}\..\..\scripts\open-panel.ps1"
```

`SKILL_DIR` is the directory containing this file. Resolve the script relative to this file when the host does not set it. After the command succeeds, tell the user the native panel is open. Do not ask for API keys in chat. The panel stores them in macOS Keychain or Windows Credential Manager.

## Switch complete Codex configurations

Use the panel's `配置方案` section. A configuration is always a pair: the complete `config.toml` plus its matching `auth.json`.

- `保存当前` captures the current pair, including ChatGPT account login state.
- `导入配置文件夹` imports a directory that contains both files.
- `新建 API 中转配置` accepts a name, URL, API Key, main model, review model, and optional model catalog path. It preserves unrelated Codex settings from the current config.
- `一键切换` replaces both live files as one transaction. Tell the user to fully quit and reopen Codex after switching.
- Auth JSON is never stored in profile metadata or plain configuration-profile files. It is stored in Keychain or Windows Credential Manager.

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
