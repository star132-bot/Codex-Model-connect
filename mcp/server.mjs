#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir, platform } from "node:os";
import { delimiter, join } from "node:path";
import { spawn } from "node:child_process";

const SERVER = { name: "codex-model-manager-delegate", version: "0.4.1" };
const keyCache = new Map();

function codexHome() {
  const configured = process.env.CODEX_HOME;
  if (configured && (configured.startsWith("/") || /^[A-Za-z]:[\\/]/.test(configured))) return configured;
  return join(process.env.USERPROFILE || process.env.HOME || homedir(), ".codex");
}

async function loadState() {
  const directory = join(codexHome(), "model-manager");
  const candidates = platform() === "win32"
    ? [join(directory, "state.windows.json"), join(directory, "state.json")]
    : [join(directory, "state.json"), join(directory, "state.windows.json")];
  const path = candidates.find(existsSync);
  if (!path) throw new Error("尚未找到模型管理器配置。请先打开面板并添加外部模型。");
  return JSON.parse(await readFile(path, "utf8"));
}

function normalizedProviders(state) {
  return (state.providers || []).map((provider) => {
    const model = provider.model || {};
    return {
      id: provider.id,
      name: provider.name || provider.id,
      baseURL: provider.baseURL || provider.baseUrl,
      protocol: provider.wireProtocol || provider.protocol || "responses",
      modelId: model.id || provider.modelId,
      displayName: model.displayName || provider.displayName || model.id || provider.modelId,
      enabled: provider.enabled !== false && model.enabled !== false,
      verified: Boolean(provider.verifiedAt),
      antigravity: (provider.baseURL || provider.baseUrl) === "antigravity://local"
    };
  }).filter((provider) => provider.id && provider.modelId && provider.enabled && provider.verified);
}

function selectProvider(state, requested) {
  const providers = normalizedProviders(state);
  if (!providers.length) throw new Error("没有已启用且通过验证的外部模型。");
  if (requested) {
    const needle = requested.toLowerCase();
    const match = providers.find((provider) =>
      provider.id.toLowerCase() === needle || provider.modelId.toLowerCase() === needle || provider.name.toLowerCase() === needle
    );
    if (!match) throw new Error(`找不到外部模型：${requested}`);
    return match;
  }
  const activeId = state.activeProviderID || state.activeProviderId;
  return providers.find((provider) => provider.id === activeId) || providers[0];
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    const stdout = [], stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      const output = Buffer.concat(stdout).toString("utf8");
      const error = Buffer.concat(stderr).toString("utf8");
      if (code === 0) resolve(output);
      else reject(new Error((error || output || `${command} exited with ${code}`).trim()));
    });
  });
}

async function readKey(account) {
  if (keyCache.has(account)) return keyCache.get(account);
  let key;
  if (platform() === "darwin") {
    key = (await run("/usr/bin/security", ["find-generic-password", "-s", "local.codex.model-manager", "-a", account, "-w"])).trim();
  } else if (platform() === "win32") {
    const executable = join(process.env.LOCALAPPDATA || "", "CodexModelManager", "CodexModelManager.exe");
    if (!existsSync(executable)) throw new Error("找不到 Windows 模型管理器，请先完成安装。");
    key = (await run(executable, ["--print-key", account])).trim();
  } else {
    throw new Error("当前系统暂不支持从安全凭据库读取模型密钥。");
  }
  if (!key) throw new Error(`没有找到 ${account} 的 API Key。`);
  keyCache.set(account, key);
  return key;
}

async function requestJSON(url, options) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(10 * 60 * 1000) });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  if (!response.ok) {
    const detail = json?.error?.message || json?.message || text.slice(0, 500);
    throw new Error(`外部模型请求失败：HTTP ${response.status} ${detail}`);
  }
  if (!json) throw new Error("外部模型返回了无法解析的响应。");
  return json;
}

function extractResponsesText(json) {
  if (typeof json.output_text === "string" && json.output_text) return json.output_text;
  const parts = [];
  for (const item of json.output || []) for (const content of item.content || []) {
    if (typeof content.text === "string") parts.push(content.text);
    else if (typeof content.output_text === "string") parts.push(content.output_text);
  }
  return parts.join("\n").trim();
}

async function callDirect(provider, prompt, maxOutputTokens) {
  const key = await readKey(provider.id);
  const base = String(provider.baseURL || "").replace(/\/+$/, "");
  if (provider.protocol === "chatCompletions") {
    const json = await requestJSON(`${base}/chat/completions`, {
      method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: provider.modelId, messages: [{ role: "user", content: prompt }], max_tokens: maxOutputTokens, stream: false })
    });
    const content = json.choices?.[0]?.message?.content;
    const text = typeof content === "string" ? content : Array.isArray(content) ? content.map((part) => part.text || "").join("") : "";
    if (!text) throw new Error("外部模型没有返回文本内容。");
    return text;
  }
  if (provider.protocol === "gemini") {
    const json = await requestJSON(`${base}/models/${encodeURIComponent(provider.modelId)}:generateContent?key=${encodeURIComponent(key)}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: prompt }] }], generationConfig: { maxOutputTokens } })
    });
    const text = (json.candidates?.[0]?.content?.parts || []).map((part) => part.text || "").join("").trim();
    if (!text) throw new Error("Gemini 没有返回文本内容。");
    return text;
  }
  const json = await requestJSON(`${base}/responses`, {
    method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: provider.modelId, input: prompt, max_output_tokens: maxOutputTokens, stream: false })
  });
  const text = extractResponsesText(json);
  if (!text) throw new Error("Responses 接口没有返回文本内容。");
  return text;
}

function findAgy() {
  const home = process.env.USERPROFILE || process.env.HOME || homedir();
  const candidates = platform() === "win32"
    ? [join(process.env.LOCALAPPDATA || "", "agy", "bin", "agy.exe"), join(home, ".local", "bin", "agy.exe")]
    : [join(home, ".local", "bin", "agy"), "/usr/local/bin/agy", "/opt/homebrew/bin/agy"];
  const exact = candidates.find(existsSync);
  if (exact) return exact;
  for (const folder of (process.env.PATH || "").split(delimiter)) {
    const path = join(folder, platform() === "win32" ? "agy.exe" : "agy");
    if (existsSync(path)) return path;
  }
  throw new Error("找不到 Antigravity CLI。请先在模型管理器中点击一键安装。");
}

async function callAntigravity(provider, prompt) {
  const output = await run(findAgy(), ["-p", prompt, "--model", provider.modelId, "--mode", "plan", "--sandbox", "--output-format", "json", "--print-timeout", "10m"]);
  for (const line of output.replace(/\r/g, "").split("\n").filter(Boolean).reverse()) {
    try {
      const json = JSON.parse(line);
      if (typeof json.response === "string" && json.response) return json.response;
    } catch { /* keep looking for the JSON result */ }
  }
  if (output.trim()) return output.trim();
  throw new Error("Antigravity 没有返回文本内容。");
}

function promptFor(task, context) {
  const guardrail = "You are a delegated reasoning model. Solve only the requested subtask and return a precise result to the supervising Codex agent. You do not have access to its local files or tools unless relevant content is included below. Do not claim that you changed files or executed commands.";
  return context ? `${guardrail}\n\nContext:\n${context}\n\nTask:\n${task}` : `${guardrail}\n\nTask:\n${task}`;
}

const tools = [
  {
    name: "list_delegate_models",
    description: "List enabled, verified external models stored by Codex Model Manager. Reads only independent model-manager state and never modifies config.toml.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }
  },
  {
    name: "delegate_task",
    description: "Delegate a text-only reasoning subtask to a configured external model. The current Codex agent retains local tools and must verify/apply the result. No local files are sent unless their contents are explicitly supplied in context. Never modifies config.toml.",
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "string", description: "A concrete, self-contained subtask." },
        model: { type: "string", description: "Optional provider ID, provider name, or model ID. Omit to use the default delegate." },
        context: { type: "string", description: "Optional relevant context. Do not include secrets." },
        max_output_tokens: { type: "integer", minimum: 64, maximum: 32768, default: 4096 }
      },
      required: ["task"], additionalProperties: false
    }
  }
];

async function callTool(name, args = {}) {
  const state = await loadState();
  if (name === "list_delegate_models") {
    const models = normalizedProviders(state).map(({ id, name, modelId, displayName, protocol, antigravity }) => ({ id, name, model: modelId, displayName, protocol: antigravity ? "antigravity" : protocol }));
    const activeProviderId = state.activeProviderID || state.activeProviderId;
    return {
      content: [{ type: "text", text: models.map((item) => `${item.id === activeProviderId ? "★" : "•"} ${item.name} · ${item.model} · ${item.protocol}`).join("\n") || "没有可用的外部模型。" }],
      structuredContent: { activeProviderId, models }
    };
  }
  if (name !== "delegate_task") throw new Error(`未知工具：${name}`);
  if (typeof args.task !== "string" || !args.task.trim()) throw new Error("task 不能为空。");
  const provider = selectProvider(state, typeof args.model === "string" ? args.model.trim() : "");
  const prompt = promptFor(args.task.trim(), typeof args.context === "string" ? args.context.trim() : "");
  const maxOutputTokens = Math.max(64, Math.min(32768, Number(args.max_output_tokens) || 4096));
  const answer = provider.antigravity ? await callAntigravity(provider, prompt) : await callDirect(provider, prompt, maxOutputTokens);
  return {
    content: [{ type: "text", text: `[${provider.name} · ${provider.modelId}]\n${answer}` }],
    structuredContent: { providerId: provider.id, provider: provider.name, model: provider.modelId, answer }
  };
}

async function handle(message) {
  if (message.method === "initialize") return { protocolVersion: message.params?.protocolVersion || "2024-11-05", capabilities: { tools: { listChanged: false } }, serverInfo: SERVER };
  if (message.method === "ping") return {};
  if (message.method === "tools/list") return { tools };
  if (message.method === "tools/call") return await callTool(message.params?.name, message.params?.arguments || {});
  if (message.method?.startsWith("notifications/")) return undefined;
  throw Object.assign(new Error(`Method not found: ${message.method}`), { code: -32601 });
}

function send(message) { process.stdout.write(`${JSON.stringify(message)}\n`); }

async function dispatch(message) {
  if (message.id === undefined || message.id === null) {
    try { await handle(message); } catch (error) { process.stderr.write(`${error.message}\n`); }
    return;
  }
  try { send({ jsonrpc: "2.0", id: message.id, result: await handle(message) }); }
  catch (error) { send({ jsonrpc: "2.0", id: message.id, error: { code: error.code || -32000, message: error.message || String(error) } }); }
}

let input = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  while (input.length) {
    const headerEnd = input.indexOf("\r\n\r\n");
    if (headerEnd >= 0 && input.subarray(0, headerEnd).toString("utf8").toLowerCase().includes("content-length:")) {
      const header = input.subarray(0, headerEnd).toString("utf8");
      const length = Number(/content-length:\s*(\d+)/i.exec(header)?.[1] || 0);
      if (input.length < headerEnd + 4 + length) break;
      const body = input.subarray(headerEnd + 4, headerEnd + 4 + length).toString("utf8");
      input = input.subarray(headerEnd + 4 + length);
      try { void dispatch(JSON.parse(body)); } catch (error) { process.stderr.write(`${error.message}\n`); }
      continue;
    }
    const newline = input.indexOf(10);
    if (newline < 0) break;
    const line = input.subarray(0, newline).toString("utf8").trim();
    input = input.subarray(newline + 1);
    if (line) {
      try { void dispatch(JSON.parse(line)); } catch (error) { process.stderr.write(`${error.message}\n`); }
    }
  }
});
