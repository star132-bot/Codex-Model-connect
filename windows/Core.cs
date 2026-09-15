using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CodexModelManager.Windows;

public sealed class ProviderRecord
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string BaseUrl { get; set; } = "";
    public string Protocol { get; set; } = "responses";
    public string ModelId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public DateTimeOffset? VerifiedAt { get; set; }
    [JsonIgnore] public bool CanActivate => Enabled && VerifiedAt is not null;
    [JsonIgnore] public bool IsAntigravity => BaseUrl == "antigravity://local";
}

public sealed class WindowsState
{
    public List<ProviderRecord> Providers { get; set; } = [];
    public string ActiveProviderId { get; set; } = "openai";
    public string ActiveModel { get; set; } = "gpt-5.6-sol";
    public string OpenAIModel { get; set; } = "gpt-5.6-sol";
    public string ConfigurationMode { get; set; } = "desktopMenu";
    public string? ExternalProviderId { get; set; }
    public string? RouterSecret { get; set; }
}

internal static class Paths
{
    public static readonly string CodexHome = ResolveCodexHome();
    public static readonly string Data = Path.Combine(CodexHome, "model-manager");
    public static readonly string State = Path.Combine(Data, "state.windows.json");
    public static readonly string RouterState = Path.Combine(Data, "router-state.windows.json");
    public static readonly string Config = Path.Combine(CodexHome, "config.toml");
    public static readonly string Profile = Path.Combine(CodexHome, "config_out.config.toml");
    public static readonly string BaseCatalog = Path.Combine(Data, "base-model-catalog.windows.json");
    public static readonly string ActiveCatalog = Path.Combine(Data, "active-model-catalog.windows.json");
    public static readonly string ExternalCatalog = Path.Combine(Data, "external-model-catalog.windows.json");
    public static string Executable => Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule!.FileName;

    private static string ResolveCodexHome()
    {
        var configured = Environment.GetEnvironmentVariable("CODEX_HOME");
        return !string.IsNullOrWhiteSpace(configured) && Path.IsPathFullyQualified(configured) ? Path.GetFullPath(configured)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    }
}

public static class CredentialStore
{
    private const string Prefix = "CodexModelManager/";
    private static readonly object Gate = new();
    private static readonly Dictionary<string, string> Cache = new(StringComparer.Ordinal);

    public static string? Read(string account)
    {
        lock (Gate) if (Cache.TryGetValue(account, out var cached)) return cached;
        if (!CredRead(Prefix + account, 1, 0, out var pointer)) return null;
        try
        {
            var native = Marshal.PtrToStructure<CREDENTIAL>(pointer);
            if (native.CredentialBlobSize == 0) return "";
            var bytes = new byte[native.CredentialBlobSize];
            Marshal.Copy(native.CredentialBlob, bytes, 0, bytes.Length);
            var value = Encoding.Unicode.GetString(bytes).TrimEnd('\0');
            lock (Gate) Cache[account] = value;
            return value;
        }
        finally { CredFree(pointer); }
    }

    public static bool Exists(string account) => Read(account) is { Length: > 0 };

    public static void Save(string account, string value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException("API Key 不能为空");
        var bytes = Encoding.Unicode.GetBytes(value);
        var blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new CREDENTIAL {
                Type = 1, TargetName = Prefix + account, CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob, Persist = 2, UserName = Environment.UserName
            };
            if (!CredWrite(ref credential, 0)) throw new InvalidOperationException($"写入 Windows Credential Manager 失败（{Marshal.GetLastWin32Error()}）");
            lock (Gate) Cache[account] = value;
        }
        finally { Marshal.FreeCoTaskMem(blob); }
    }

    public static void Delete(string account)
    {
        CredDelete(Prefix + account, 1, 0);
        lock (Gate) Cache.Remove(account);
    }

    public static bool Print(string? account)
    {
        if (account is null || Read(account) is not { Length: > 0 } key) return false;
        var bytes = Encoding.UTF8.GetBytes(key);
        using var output = Console.OpenStandardOutput();
        output.Write(bytes, 0, bytes.Length);
        return true;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }
    [DllImport("advapi32", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite([In] ref CREDENTIAL credential, uint flags);
    [DllImport("advapi32", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32", SetLastError = true)] private static extern void CredFree(IntPtr credential);
}

public static class ProviderClient
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(35) };

    public static async Task<List<string>> FetchModelsAsync(string baseUrl, string key, string protocol)
    {
        var root = Normalize(baseUrl);
        var url = protocol == "gemini" ? $"{root}/models?key={Uri.EscapeDataString(key)}" : $"{root}/models";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (protocol != "gemini") request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await Client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, text);
        using var json = JsonDocument.Parse(text);
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (json.RootElement.TryGetProperty("data", out var data))
            foreach (var row in data.EnumerateArray()) if (row.TryGetProperty("id", out var id)) result.Add(id.GetString() ?? "");
        if (json.RootElement.TryGetProperty("models", out var models))
            foreach (var row in models.EnumerateArray()) if (row.TryGetProperty("name", out var name)) result.Add((name.GetString() ?? "").Replace("models/", ""));
        result.Remove("");
        if (result.Count == 0) throw new InvalidOperationException("模型接口可访问，但没有识别到模型 ID");
        return result.OrderBy(value => value, StringComparer.Ordinal).ToList();
    }

    public static async Task TestAsync(string baseUrl, string key, string model, string protocol)
    {
        var root = Normalize(baseUrl);
        string url; object body;
        if (protocol == "responses") { url = $"{root}/responses"; body = new { model, input = "Reply with OK only.", max_output_tokens = 16, stream = false }; }
        else if (protocol == "chatCompletions") { url = $"{root}/chat/completions"; body = new { model, messages = new[] { new { role = "user", content = "Reply with OK only." } }, max_tokens = 16, stream = false }; }
        else { url = $"{root}/models/{Uri.EscapeDataString(model)}:generateContent?key={Uri.EscapeDataString(key)}"; body = new { contents = new[] { new { parts = new[] { new { text = "Reply with OK only." } } } } }; }
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
        if (protocol != "gemini") request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await Client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync(); EnsureSuccess(response, text);
    }

    private static string Normalize(string value)
    {
        if (!Uri.TryCreate(value.Trim().TrimEnd('/'), UriKind.Absolute, out var uri) || (uri.Scheme != "https" && uri.Scheme != "http"))
            throw new InvalidOperationException("请输入有效的 http(s) API Base URL");
        return uri.AbsoluteUri.TrimEnd('/');
    }
    private static void EnsureSuccess(HttpResponseMessage response, string body)
    {
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"API 请求失败：HTTP {(int)response.StatusCode} {body.Replace("\r", " ").Replace("\n", " ")[..Math.Min(220, body.Length)]}");
    }
}

public sealed class ManagerService
{
    public WindowsState State { get; private set; }
    public string ActiveTitle => State.ActiveProviderId == "openai" ? $"安全委派：未设置 · 本地 GPT · {State.OpenAIModel}"
        : $"安全委派：默认 · {State.Providers.FirstOrDefault(p => p.Id == State.ActiveProviderId)?.Name} · {State.ActiveModel}";

    public ManagerService()
    {
        Directory.CreateDirectory(Paths.Data);
        State = File.Exists(Paths.State) ? JsonSerializer.Deserialize<WindowsState>(File.ReadAllText(Paths.State), JsonOptions()) ?? new() : new();
    }

    public void Upsert(ProviderRecord provider, string key, bool makeDefault)
    {
        CredentialStore.Save(provider.Id, key);
        var index = State.Providers.FindIndex(p => p.Id == provider.Id);
        if (index >= 0) State.Providers[index] = provider; else State.Providers.Add(provider);
        if (provider.CanActivate) {
            State.ExternalProviderId = provider.Id;
            if (makeDefault) { State.ActiveProviderId = provider.Id; State.ActiveModel = provider.ModelId; }
        }
        Sync();
    }

    public void ImportAntigravity(IEnumerable<string> models)
    {
        foreach (var model in models.Distinct(StringComparer.Ordinal)) {
            var id = "cmm_antigravity_" + new string(model.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());
            var family = model.StartsWith("gemini-") ? "Gemini" : model.StartsWith("claude-") ? "Claude" : "GPT-OSS";
            var record = new ProviderRecord { Id = id, Name = "Antigravity · " + family, BaseUrl = "antigravity://local", Protocol = "responses", ModelId = model, DisplayName = model, Enabled = true, VerifiedAt = DateTimeOffset.UtcNow };
            var index = State.Providers.FindIndex(p => p.Id == id); if (index >= 0) State.Providers[index] = record; else State.Providers.Add(record);
        }
        State.ConfigurationMode = "desktopMenu";
        Sync();
    }

    public void Delete(ProviderRecord provider)
    {
        if (!provider.IsAntigravity) CredentialStore.Delete(provider.Id); State.Providers.RemoveAll(p => p.Id == provider.Id);
        if (State.ActiveProviderId == provider.Id) { State.ActiveProviderId = "openai"; State.ActiveModel = State.OpenAIModel; }
        if (State.ExternalProviderId == provider.Id) State.ExternalProviderId = State.Providers.FirstOrDefault(p => p.CanActivate)?.Id;
        Sync();
    }
    public void UseGpt() { State.ActiveProviderId = "openai"; State.ActiveModel = State.OpenAIModel; Sync(); }
    public void SetMode(string mode) { State.ConfigurationMode = "desktopMenu"; Sync(); }

    private void Sync()
    {
        var importable = State.Providers.Where(p => p.CanActivate).ToList();
        if (State.ActiveProviderId != "openai" && importable.All(p => p.Id != State.ActiveProviderId)) { State.ActiveProviderId = "openai"; State.ActiveModel = State.OpenAIModel; }
        WriteExternalProfile(importable.Where(provider => !provider.IsAntigravity && provider.Protocol == "responses").ToList());
        // The user's main config.toml is intentionally read-only. External
        // providers are consumed by the plugin MCP delegate from separate state.
        State.ConfigurationMode = "desktopMenu";
        State.RouterSecret = null;
        RouterStartup.Disable();
        Save();
    }

    private void Save()
    {
        AtomicWrite(Paths.State, JsonSerializer.Serialize(State, JsonOptions()));
    }

    private void WriteExternalProfile(List<ProviderRecord> providers)
    {
        var selected = providers.FirstOrDefault(p => p.Id == State.ExternalProviderId) ?? providers.FirstOrDefault();
        var text = File.Exists(Paths.Profile) ? File.ReadAllText(Paths.Profile) : "# Codex Model Manager external profile\n";
        text = Toml.RemoveBlock(text, "# >>> codex-model-manager:external-profile", "# <<< codex-model-manager:external-profile");
        if (selected is null) { AtomicWrite(Paths.Profile, text.TrimEnd() + "\n"); return; }
        State.ExternalProviderId = selected.Id;
        WriteCatalog(Paths.ExternalCatalog, [selected], false);
        text = Toml.SetTop(text, "model", selected.ModelId);
        text = Toml.SetTop(text, "model_provider", selected.Id);
        text = Toml.SetTop(text, "model_catalog_json", Paths.ExternalCatalog);
        var exe = Toml.Escape(Paths.Executable);
        text = text.TrimEnd() + $"\n\n# >>> codex-model-manager:external-profile\n# Generated by Codex Model Manager for Windows.\n\n[model_providers.{selected.Id}]\nname = \"{Toml.Escape(selected.Name)}\"\nbase_url = \"{Toml.Escape(selected.BaseUrl)}\"\nwire_api = \"responses\"\n\n[model_providers.{selected.Id}.auth]\ncommand = \"{exe}\"\nargs = [\"--print-key\", \"{Toml.Escape(selected.Id)}\"]\ntimeout_ms = 3000\n\n# <<< codex-model-manager:external-profile\n";
        AtomicWrite(Paths.Profile, text);
    }

    private static void WriteCatalog(string destination, List<ProviderRecord> providers, bool includeBuiltIns)
    {
        EnsureBaseCatalog();
        var root = JsonNode.Parse(File.ReadAllText(Paths.BaseCatalog))?.AsObject() ?? throw new InvalidOperationException("无法读取 Codex 模型目录");
        var baseModels = root["models"]?.AsArray() ?? throw new InvalidOperationException("Codex 模型目录为空");
        var template = baseModels.FirstOrDefault()?.DeepClone()?.AsObject() ?? throw new InvalidOperationException("Codex 模型目录为空");
        var output = new JsonArray(); if (includeBuiltIns) foreach (var item in baseModels) output.Add(item?.DeepClone());
        var priority = 10000;
        foreach (var provider in providers) {
            var model = template.DeepClone().AsObject(); model["slug"] = provider.ModelId; model["display_name"] = provider.DisplayName;
            model["description"] = provider.Name + " · 自定义 Responses 模型"; model["priority"] = priority++; model["visibility"] = "list";
            model["supported_in_api"] = true; model["supports_search_tool"] = false; model["use_responses_lite"] = false;
            model["additional_speed_tiers"] = new JsonArray(); model["service_tiers"] = new JsonArray(); model["upgrade"] = null; model["availability_nux"] = null;
            output.Add(model);
        }
        root["models"] = output; AtomicWrite(destination, root.ToJsonString(JsonOptions()));
    }

    private static void EnsureBaseCatalog()
    {
        if (File.Exists(Paths.BaseCatalog)) return;
        var codex = FindExecutable("codex.exe") ?? FindExecutable("codex.cmd") ?? throw new InvalidOperationException("找不到 codex 命令");
        var start = new ProcessStartInfo(codex, "debug models --bundled") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        using var process = Process.Start(start)!; var output = process.StandardOutput.ReadToEnd(); var error = process.StandardError.ReadToEnd(); process.WaitForExit();
        if (process.ExitCode != 0 || JsonNode.Parse(output)?["models"] is not JsonArray) throw new InvalidOperationException("读取 Codex 模型目录失败：" + error[..Math.Min(160, error.Length)]);
        AtomicWrite(Paths.BaseCatalog, output);
    }

    internal static string? FindExecutable(string name)
    {
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)) {
            try { var path = Path.Combine(folder.Trim(), name); if (File.Exists(path)) return path; } catch { }
        }
        return null;
    }

    internal static JsonSerializerOptions JsonOptions() => new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    internal static void AtomicWrite(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!); var temporary = path + ".tmp"; File.WriteAllText(temporary, text, new UTF8Encoding(false)); File.Move(temporary, path, true);
    }
}

internal static class Toml
{
    public static string Escape(string value) => value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
    public static string? GetTop(string text, string key)
    {
        foreach (var line in text.Replace("\r", "").Split('\n')) { var t = line.Trim(); if (t.StartsWith('[')) break; if (t.StartsWith(key + " ") || t.StartsWith(key + "=")) return t[(t.IndexOf('=') + 1)..].Trim().Trim('"'); }
        return null;
    }
    public static string SetTop(string text, string key, string value)
    {
        var lines = text.Replace("\r", "").Split('\n').ToList(); var table = lines.FindIndex(x => x.TrimStart().StartsWith('[')); if (table < 0) table = lines.Count;
        for (var i = 0; i < table; i++) { var t = lines[i].Trim(); if (t.StartsWith(key + " ") || t.StartsWith(key + "=")) { lines[i] = $"{key} = \"{Escape(value)}\""; return string.Join('\n', lines); } }
        lines.Insert(table, $"{key} = \"{Escape(value)}\""); return string.Join('\n', lines);
    }
    public static string RemoveTop(string text, string key)
    {
        var lines = text.Replace("\r", "").Split('\n').ToList(); var table = lines.FindIndex(x => x.TrimStart().StartsWith('[')); if (table < 0) table = lines.Count;
        for (var i = table - 1; i >= 0; i--) { var t = lines[i].Trim(); if (t.StartsWith(key + " ") || t.StartsWith(key + "=")) lines.RemoveAt(i); }
        return string.Join('\n', lines);
    }
    public static string RemoveBlock(string text, string start, string end)
    {
        var a = text.IndexOf(start, StringComparison.Ordinal); if (a < 0) return text; var b = text.IndexOf(end, a + start.Length, StringComparison.Ordinal); if (b < 0) return text[..a]; b += end.Length; while (b < text.Length && (text[b] == '\r' || text[b] == '\n')) b++; return text.Remove(a, b - a);
    }
}

internal static class RouterStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static void Enable()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey); key.SetValue("CodexModelManagerRouter", $"\"{Paths.Executable}\" --router");
        if (!Process.GetProcessesByName(Path.GetFileNameWithoutExtension(Paths.Executable)).Any(p => p.Id != Environment.ProcessId && SafeCommandLine(p).Contains("--router")))
            Process.Start(new ProcessStartInfo(Paths.Executable, "--router") { UseShellExecute = false, CreateNoWindow = true });
    }
    public static void Disable() { using var key = Registry.CurrentUser.OpenSubKey(RunKey, true); key?.DeleteValue("CodexModelManagerRouter", false); }
    private static string SafeCommandLine(Process process) { try { return process.MainModule?.FileName ?? ""; } catch { return ""; } }
}

public static class LocalRouter
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromHours(1) };
    private static Mutex? InstanceMutex;
    public static async Task<int> RunAsync()
    {
        try {
            InstanceMutex = new Mutex(true, @"Local\CodexModelManagerRouter", out var ownsMutex);
            if (!ownsMutex) return 0;
            var listener = new TcpListener(IPAddress.Loopback, 17876); listener.Start();
            while (true) { var client = await listener.AcceptTcpClientAsync(); _ = Task.Run(() => HandleAsync(client)); }
        } catch (Exception ex) { File.AppendAllText(Path.Combine(Paths.Data, "router-error.windows.log"), DateTimeOffset.Now + " " + ex + Environment.NewLine); return 1; }
    }

    private static async Task HandleAsync(TcpClient connection)
    {
        using (connection) try {
            var request = await ReadRequestAsync(connection.GetStream());
            var state = JsonSerializer.Deserialize<WindowsState>(File.ReadAllText(Paths.RouterState), ManagerService.JsonOptions()) ?? throw new InvalidOperationException("Router state unavailable");
            if (!request.Headers.TryGetValue("X-Codex-Model-Manager-Token", out var token) || token != state.RouterSecret) { await WriteSimple(connection.GetStream(), 403, "Invalid router token"); return; }
            var model = JsonNode.Parse(request.Body)?["model"]?.GetValue<string>(); var provider = state.Providers.FirstOrDefault(p => p.CanActivate && p.ModelId == model);
            if (provider?.IsAntigravity == true) { await WriteAntigravityResponse(connection.GetStream(), request.Body, provider); return; }
            var suffix = request.Path.StartsWith("/v1", StringComparison.Ordinal) ? request.Path[3..] : request.Path;
            var baseUrl = provider?.BaseUrl.TrimEnd('/') ?? (request.Headers.ContainsKey("ChatGPT-Account-ID") ? "https://chatgpt.com/backend-api/codex" : "https://api.openai.com/v1");
            using var forwarded = new HttpRequestMessage(new HttpMethod(request.Method), baseUrl + "/" + suffix.TrimStart('/')) { Content = request.Body.Length == 0 ? null : new ByteArrayContent(request.Body) };
            foreach (var (name, value) in request.Headers) {
                if (new[] { "host", "content-length", "transfer-encoding", "connection", "proxy-connection", "accept-encoding", "x-codex-model-manager-token" }.Contains(name.ToLowerInvariant())) continue;
                if (provider is not null && new[] { "authorization", "chatgpt-account-id", "openai-organization", "openai-project", "cookie" }.Contains(name.ToLowerInvariant())) continue;
                if (!forwarded.Headers.TryAddWithoutValidation(name, value)) forwarded.Content?.Headers.TryAddWithoutValidation(name, value);
            }
            if (provider is not null) forwarded.Headers.Authorization = new AuthenticationHeaderValue("Bearer", CredentialStore.Read(provider.Id) ?? throw new InvalidOperationException("Custom provider key unavailable"));
            using var response = await Client.SendAsync(forwarded, HttpCompletionOption.ResponseHeadersRead); var body = await response.Content.ReadAsByteArrayAsync();
            await WriteResponse(connection.GetStream(), (int)response.StatusCode, response.Content.Headers.ContentType?.ToString() ?? "application/json", body);
        } catch (Exception ex) { try { await WriteSimple(connection.GetStream(), 502, ex.Message); } catch { } }
    }

    private sealed record Request(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);

    private static async Task WriteAntigravityResponse(Stream stream, byte[] body, ProviderRecord provider)
    {
        var request = JsonNode.Parse(body)?.AsObject() ?? throw new InvalidOperationException("Invalid Responses request");
        var prompt = new StringBuilder("You are the language model behind a Codex client. Do not call Antigravity tools. Answer directly as plain text.\n\n");
        if (request["instructions"]?.GetValue<string>() is { Length: > 0 } instructions) prompt.AppendLine("Instructions:\n" + instructions);
        if (request["input"] is JsonValue value && value.TryGetValue<string>(out var input)) prompt.AppendLine("User:\n" + input);
        else if (request["input"] is JsonArray items) foreach (var item in items) prompt.AppendLine(item?.ToJsonString());
        var result = await AgyService.RunAsync(["-p", prompt.ToString(), "--model", provider.ModelId, "--mode", "plan", "--sandbox", "--output-format", "json", "--print-timeout", "10m"]);
        if (result.ExitCode != 0) throw new InvalidOperationException("Antigravity request failed: " + result.Output);
        var jsonLine = result.Output.Replace("\r", "").Split('\n').Reverse().FirstOrDefault(line => line.TrimStart().StartsWith('{')) ?? result.Output;
        var envelope = JsonNode.Parse(jsonLine)?.AsObject() ?? throw new InvalidOperationException("Invalid Antigravity response");
        var text = envelope["response"]?.GetValue<string>() ?? ""; var responseId = "resp_" + Guid.NewGuid().ToString("N"); var messageId = "msg_" + Guid.NewGuid().ToString("N");
        var response = new JsonObject { ["id"] = responseId, ["object"] = "response", ["created_at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(), ["status"] = "completed", ["error"] = null, ["incomplete_details"] = null, ["model"] = provider.ModelId,
            ["output"] = new JsonArray(new JsonObject { ["id"] = messageId, ["type"] = "message", ["status"] = "completed", ["role"] = "assistant", ["content"] = new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = text, ["annotations"] = new JsonArray() }) }),
            ["parallel_tool_calls"] = false, ["store"] = false, ["usage"] = envelope["usage"]?.DeepClone() ?? new JsonObject { ["input_tokens"] = 0, ["output_tokens"] = 0, ["total_tokens"] = 0 } };
        if (request["stream"]?.GetValue<bool>() != true) { await WriteResponse(stream, 200, "application/json", Encoding.UTF8.GetBytes(response.ToJsonString())); return; }
        var events = new[] {
            new JsonObject { ["type"]="response.created", ["response"]=new JsonObject { ["id"]=responseId,["object"]="response",["status"]="in_progress",["model"]=provider.ModelId,["output"]=new JsonArray() } },
            new JsonObject { ["type"]="response.output_item.added",["output_index"]=0,["item"]=new JsonObject{{"id",messageId},{"type","message"},{"status","in_progress"},{"role","assistant"},{"content",new JsonArray()}} },
            new JsonObject { ["type"]="response.content_part.added",["item_id"]=messageId,["output_index"]=0,["content_index"]=0,["part"]=new JsonObject{{"type","output_text"},{"text",""},{"annotations",new JsonArray()}} },
            new JsonObject { ["type"]="response.output_text.delta",["item_id"]=messageId,["output_index"]=0,["content_index"]=0,["delta"]=text },
            new JsonObject { ["type"]="response.output_text.done",["item_id"]=messageId,["output_index"]=0,["content_index"]=0,["text"]=text },
            new JsonObject { ["type"]="response.output_item.done",["output_index"]=0,["item"]=response["output"]![0]!.DeepClone() },
            new JsonObject { ["type"]="response.completed",["response"]=response.DeepClone() }
        };
        var sse = new StringBuilder(); for (var i=0;i<events.Length;i++) { events[i]["sequence_number"]=i; sse.Append("event: ").Append(events[i]["type"]!.GetValue<string>()).Append("\ndata: ").Append(events[i].ToJsonString()).Append("\n\n"); }
        await WriteResponse(stream, 200, "text/event-stream", Encoding.UTF8.GetBytes(sse.ToString()));
    }
    private static async Task<Request> ReadRequestAsync(NetworkStream stream)
    {
        var data = new List<byte>(); var buffer = new byte[8192]; var marker = Encoding.ASCII.GetBytes("\r\n\r\n"); var headerEnd = -1;
        while (headerEnd < 0 && data.Count < 1_048_576) { var count = await stream.ReadAsync(buffer); if (count <= 0) throw new IOException("Incomplete request"); data.AddRange(buffer.AsSpan(0, count).ToArray()); headerEnd = IndexOf(data, marker); }
        var head = Encoding.UTF8.GetString(data.Take(headerEnd).ToArray()).Split("\r\n"); var first = head[0].Split(' ', 3); var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in head.Skip(1)) { var colon = line.IndexOf(':'); if (colon > 0) headers[line[..colon].Trim()] = line[(colon + 1)..].Trim(); }
        var length = headers.TryGetValue("Content-Length", out var raw) && int.TryParse(raw, out var n) ? n : 0; var body = data.Skip(headerEnd + 4).ToList();
        while (body.Count < length) { var count = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, length - body.Count))); if (count <= 0) throw new IOException("Incomplete body"); body.AddRange(buffer.AsSpan(0, count).ToArray()); }
        return new(first[0], first[1], headers, body.Take(length).ToArray());
    }
    private static int IndexOf(List<byte> source, byte[] value) { for (var i = 0; i <= source.Count - value.Length; i++) { var found = true; for (var j = 0; j < value.Length; j++) if (source[i + j] != value[j]) { found = false; break; } if (found) return i; } return -1; }
    private static Task WriteSimple(Stream stream, int status, string message) => WriteResponse(stream, status, "application/json", Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { error = new { message } })));
    private static async Task WriteResponse(Stream stream, int status, string contentType, byte[] body)
    {
        var reason = status is >= 200 and < 300 ? "OK" : "Error"; var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"); await stream.WriteAsync(head); await stream.WriteAsync(body);
    }
}
