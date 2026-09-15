# Codex 模型管理器

原生 macOS SwiftUI / Windows WPF 模型面板，并为 Codex 提供 `delegate_task` 本地工具。它不是网页。

## 为什么改成“安全委派”

ChatGPT 账号创建的 Codex 任务会固定使用 OpenAI provider。把 `grok-4.6` 或 Gemini 塞进同一个模型下拉框，并不能把已有任务切换到另一个厂商；请求仍会发到 ChatGPT 账号端点，于是出现 `model is not supported when using Codex with a ChatGPT account`。

本项目采用可稳定共存的方式：当前 Codex 始终保留 GPT 和本地文件、终端、浏览器等工具；它可以调用 `delegate_task`，把一个明确的文字子任务交给 Grok、Gemini、Claude、GPT-OSS 或 Antigravity，再检查和使用返回结果。

## 配置隔离保证

- `~/.codex/config.toml` 始终只读，管理器不会添加、删除或改写其中任何字段。
- 外部厂商、启用状态、默认委派模型写入 `~/.codex/model-manager/state.json`（Windows 为 `state.windows.json`）。
- Responses 兼容厂商还会生成独立的 `~/.codex/config_out.config.toml`，供 `codex --profile config_out` 使用。
- API Key 只保存在 macOS Keychain 或 Windows Credential Manager；MCP 委派进程首次解锁后只在内存中缓存。
- Antigravity 登录完全由 `agy` 管理，不复制 Google 凭据。

## 功能

- 添加/编辑厂商名称、API Base URL、API Key 和协议类型
- 拉取模型列表；每个厂商保留一个选中模型
- 导入前发送最小真实请求进行验证
- 启用、禁用、删除和设置默认委派模型
- 支持 OpenAI Responses、Chat Completions、Gemini `generateContent`
- Antigravity 一键安装、Google 登录、模型与额度查询、模型测试
- `list_delegate_models`：查看可委派模型
- `delegate_task`：在当前 Codex 任务中调用外部模型做文字推理

外部模型不会自动看到本地文件或拥有 Codex 工具。只有 Codex 明确放进 `context` 的内容会被发送；外部返回值是建议或草稿，最终的读取、修改和验证仍由当前 Codex 完成。

## 安装

从 GitHub Releases 下载对应压缩包：

- macOS：解压并双击 `Install Codex Model Manager.command`
- Windows x64：解压后运行 `Install.ps1`，安装到 `%LOCALAPPDATA%\CodexModelManager`

要使用任务委派工具，请从 GitHub 仓库安装 Codex 插件：

```bash
codex plugin marketplace add star132-bot/Codex-Model-connect
codex plugin add codex-model-manager@codex-model-connect
```

插件更新后需要新建一个 Codex 任务，让 `model_delegate` MCP 工具完成发现；这不是切换模型厂商，也不会修改主配置。

## 打开面板

在 Codex 输入 `$codex-model-manager`，或直接运行：

```bash
bash "$HOME/plugins/codex-model-manager/scripts/open-panel.sh"
```

Windows PowerShell：

```powershell
& "$HOME\plugins\codex-model-manager\scripts\open-panel.ps1"
```

独立外部 CLI profile 仍可使用：

```bash
codex --profile config_out
```

## 委派示例

安装插件并新建任务后，可以直接说：

> 把这个算法设计交给 Grok 分析，再由你检查并实现。

> 让 Antigravity 的 Claude 审查这段方案，只把必要上下文发给它。

Codex 会选择指定模型调用 `delegate_task`，然后继续使用自己的本地工具完成工作。
