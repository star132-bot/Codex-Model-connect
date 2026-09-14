# Codex 模型管理器

这是一个 Codex 模型管理插件，提供原生 macOS SwiftUI 和 Windows WPF 快捷面板，不是网页。

## 功能

- 添加和编辑厂商名称、API Base URL、API Key 与协议类型
- 从厂商的模型接口拉取列表，并且每个厂商只保留一个选中的模型
- 导入前发送真实 API 请求进行验证
- 新厂商默认在验证保存后设为新任务的外部主模型
- 启用、禁用、删除厂商或模型
- 设置新任务使用本地 GPT 或指定外部模型
- API Key 写入 macOS Keychain 或 Windows Credential Manager，解锁后只缓存在当前进程内存
- 外部模型默认写入独立的 `~/.codex/config_out.config.toml` profile，绝不把厂商 URL/模型表写进本地 GPT 配置
- 可选的“桌面菜单兼容”模式会生成本地路由器，把已验证模型追加到桌面下拉菜单
- 原生 Antigravity 账号面板：一键安装 `agy` CLI、打开 Google 登录、同步模型、查询额度，并将测试通过的模型导入 Codex
- 配置写入前在 `~/.codex/model-manager/backups/` 创建备份，文件权限为 600

## 下载与安装

在 GitHub Releases 下载当前系统的压缩包：

- macOS：解压后双击 `Install Codex Model Manager.command`
- Windows x64：解压后右键 PowerShell 运行 `Install.ps1`，安装到 `%LOCALAPPDATA%\CodexModelManager`

Windows 版会把本地路由器注册为当前用户启动项，不需要管理员权限。

## 打开

在 Codex 输入 `$codex-model-manager`，或从 `/` 命令列表选择已启用的 `codex-model-manager` 技能。面板是原生 macOS SwiftUI 窗口，不是网页，也不启动 Web 服务。也可以直接运行：

```bash
bash "$HOME/plugins/codex-model-manager/scripts/open-panel.sh"
```

Windows PowerShell：

```powershell
& "$HOME\plugins\codex-model-manager\scripts\open-panel.ps1"
```

也可以直接从终端启动隔离的外部模式：

```bash
bash "$HOME/plugins/codex-model-manager/scripts/open-external.sh"
```

## 协议边界

Codex 自定义厂商目前只支持 Responses API。面板也能拉取和测试 OpenAI Chat Completions 以及 Gemini `generateContent`，但不会把它们直接导入 Codex。DeepSeek 或 Gemini 若要成为 Codex 主模型，所填地址必须由厂商或你的网关提供 Responses 兼容端点。

Gemini 兼容网关有一个已知限制：Gemini 3 在同一轮同时收到内置工具（例如 web search）和函数声明时，要求额外的 `tool_config.include_server_side_tool_invocations` 字段，而 OpenAI Responses 请求没有这个 Gemini 专用字段。桌面菜单兼容模式的本地路由器会在检测到 Gemini 模型的这种组合时自动移除内置工具，保留 Codex 的函数调用；只使用函数工具的请求不受影响。若必须使用 Gemini 的原生内置工具，需要网关自行完成该字段转换。

默认“隔离配置”会保持用户级 `~/.codex/config.toml` 为本地 GPT，并把外部 profile 写到 `~/.codex/config_out.config.toml`。Codex 官方 profile 文件名固定为 `<name>.config.toml`，所以 `config_out` 通过下面的命令使用：

```bash
codex --profile config_out
```

这个 profile 只适用于 Codex CLI/TUI；当前 Codex Desktop 的 app-server 还没有 profile 入口，因此隔离模式下外部模型不会出现在 Desktop 的原生下拉菜单。若必须在 Desktop 下拉中同时看到 GPT 与外部模型，可在面板选择“桌面菜单兼容”，它会保留本地路由器并生成合并目录；这种模式的模型列表会混合显示，这是 Codex 当前模型目录没有厂商分组字段造成的限制。

Codex 会在任务创建时固定模型厂商。由 ChatGPT 账号的 OpenAI provider 创建的已有任务，即使下拉菜单后来出现 Grok、Gemini 等外部模型，也不能在同一任务中跨厂商切换；请求仍会发给 ChatGPT 账号端点并返回 “model is not supported” 错误。启用桌面兼容并完全重启 Codex 后，请新建任务，在发送第一条消息前选择外部模型。面板中的“新任务默认”只影响之后创建的任务。

面板里的 Antigravity 账号面板会调用 Google 官方安装脚本：macOS 安装到 `~/.local/bin/agy`，Windows 安装到 `%LOCALAPPDATA%\agy\bin`。它不会读取或保存 Google 登录凭据；登录由 `agy` 通过系统安全凭据完成。面板读取 `agy models` 和 `/usage` 输出，并把测试通过的模型导入 Codex 桌面模型菜单。

## 凭据与密码框

macOS 版仅在面板或后台路由器首次访问某厂商时请求 Keychain 授权。授权成功后，API Key 仅保存在该进程内存中，切换模型或后续请求不再弹框；退出应用或重启路由器后内存缓存自动清空。Windows Credential Manager 默认不会在每次读取时请求密码。

Antigravity CLI 当前没有提供可复用的 OpenAI 函数调用协议，因此这条实验桥接支持流式文本回复，暂不支持 Codex 原生工具调用。每次响应会消耗 Antigravity 账号额度，并包含 `agy` 自身代理上下文的 token 开销。Antigravity 模型只在“桌面菜单兼容”模式下导入；完全重启 Codex 后，在新任务发送第一条消息前选择它。

`model_catalog_json` 只在启动时读取。切换配置模式或更新模型后，请完全退出对应的 Codex CLI/TUI 或 Desktop/app-server，再创建新任务。
