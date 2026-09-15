import SwiftUI
import Combine
import Foundation
import Security
import AppKit

private let keychainService = "local.codex.model-manager"
private let managedBlockStart = "# >>> codex-model-manager:providers"
private let managedBlockEnd = "# <<< codex-model-manager:providers"
private let externalProfileName = "config_out"
private let externalProfileFileName = "config_out.config.toml"
private let externalProfileMarkerStart = "# >>> codex-model-manager:external-profile"
private let externalProfileMarkerEnd = "# <<< codex-model-manager:external-profile"

/// Resolve the same Codex home directory used by the CLI.  `CODEX_HOME` is
/// allowed to be an absolute path (or a path beginning with `~`); malformed or
/// relative values are ignored so a bad environment variable cannot redirect
/// writes to an unexpected location.
func codexHomeDirectory() -> URL {
    let fileManager = FileManager.default
    if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"], !raw.isEmpty {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
    }
    return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
}

enum ConfigurationMode: String, Codable, CaseIterable, Identifiable {
    case isolatedProfile
    case desktopMenu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolatedProfile: return "隔离配置"
        case .desktopMenu: return "安全委派"
        }
    }

    var description: String {
        switch self {
        case .isolatedProfile:
            return "外部模型保存在 config_out 和模型管理器目录。"
        case .desktopMenu:
            return "Codex 保留本地工具，通过 delegate_task 把子任务交给外部模型。"
        }
    }
}

enum ProviderWireProtocol: String, Codable, CaseIterable, Identifiable {
    case responses
    case chatCompletions
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .responses: return "OpenAI Responses"
        case .chatCompletions: return "OpenAI Chat Completions"
        case .gemini: return "Gemini generateContent"
        }
    }

    var codexCompatible: Bool { self == .responses }

    var note: String { codexCompatible ? "可委派 · 可用于 config_out" : "可委派" }
}

struct ManagedModel: Codable, Equatable {
    var id: String
    var displayName: String
    var enabled: Bool
}

struct AntigravitySnapshot: Equatable, Sendable {
    var executablePath: String?
    var version: String?
    var models: [String]
    var usageReport: String?
    var message: String

    init(
        executablePath: String? = nil,
        version: String? = nil,
        models: [String] = [],
        usageReport: String? = nil,
        message: String = "尚未检测"
    ) {
        self.executablePath = executablePath
        self.version = version
        self.models = models
        self.usageReport = usageReport
        self.message = message
    }

    var installed: Bool { executablePath != nil }
}

struct AntigravityCLI: Sendable {
    struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private static let officialInstaller = URL(string: "https://antigravity.google/cli/install.sh")!

    static func detect() -> AntigravitySnapshot {
        guard let executable = findExecutable() else {
            return AntigravitySnapshot(message: "未安装 agy CLI")
        }
        let version = run(executable, arguments: ["--version"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelResult = run(executable, arguments: ["models"])
        let models = parseModels(modelResult.output)
        return AntigravitySnapshot(
            executablePath: executable.path,
            version: version.isEmpty ? nil : version,
            models: models,
            message: models.isEmpty ? "已安装；请先登录 Antigravity" : "已安装并读取模型列表"
        )
    }

    static func install() -> AntigravitySnapshot {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-install-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: temp) }
        let download = run(URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
            "-fsSL", officialInstaller.absoluteString, "-o", temp.path
        ])
        guard download.status == 0 else {
            return AntigravitySnapshot(message: "下载官方安装脚本失败：\(download.output.lastLines(4))")
        }
        let install = run(URL(fileURLWithPath: "/bin/bash"), arguments: [temp.path])
        guard install.status == 0 else {
            return AntigravitySnapshot(message: "安装失败：\(install.output.lastLines(6))")
        }
        var snapshot = detect()
        if snapshot.installed {
            snapshot.message = "安装完成；请点击“打开登录”完成 Google 账号登录"
        } else {
            snapshot.message = "安装脚本已完成，但找不到 agy；请重新检测"
        }
        return snapshot
    }

    static func usage(executablePath: String) -> String {
        let result = run(URL(fileURLWithPath: executablePath), arguments: [
            "-p", "/usage", "--output-format", "text"
        ])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func test(executablePath: String, model: String) -> CommandResult {
        run(URL(fileURLWithPath: executablePath), arguments: [
            "-p", "Reply with OK only.", "--model", model,
            "--output-format", "json", "--print-timeout", "30s"
        ])
    }

    static func bridge(model: String, prompt: String) -> CommandResult {
        guard let executable = findExecutable() else {
            return CommandResult(status: -1, output: "agy CLI is not installed")
        }
        return run(executable, arguments: [
            "-p", prompt,
            "--model", model,
            "--mode", "plan",
            "--sandbox",
            "--output-format", "json",
            "--print-timeout", "10m"
        ])
    }

    static func openLoginScript(executablePath: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("antigravity-login.command")
        let escaped = shellQuote(executablePath)
        let text = "#!/bin/zsh\n\(escaped)\necho\necho '登录完成后可关闭此窗口。'\nread -k 1\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy")
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("agy")
            }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static func parseModels(_ output: String) -> [String] {
        let prefixes = ["gemini-", "claude-", "gpt-oss-"]
        var result = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" }) {
                let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "`(),"))
                if prefixes.contains(where: { value.hasPrefix($0) }) {
                    result.insert(value)
                }
            }
        }
        return result.sorted()
    }

    private static func run(_ executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = environment["PATH"] ?? ""
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(path)"
        process.environment = environment
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus,
                                 output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    func lastLines(_ count: Int) -> String {
        components(separatedBy: .newlines).suffix(count).joined(separator: " ")
    }
}

struct ModelProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var wireProtocol: ProviderWireProtocol
    var model: ManagedModel
    var enabled: Bool
    var verifiedAt: Date?

    var canActivate: Bool {
        enabled && model.enabled && verifiedAt != nil
    }

    var isAntigravityBridge: Bool {
        baseURL == "antigravity://local"
    }

    /// Gemini OpenAI-compatible relays commonly translate Responses requests to
    /// Generate Content. Gemini rejects a turn that mixes a server-side built-in
    /// tool with client-side function declarations unless the relay forwards a
    /// provider-specific tool_config flag.
    var isGeminiLike: Bool {
        let haystack = "\(name) \(model.id) \(baseURL)".lowercased()
        return haystack.contains("gemini") || haystack.contains("google")
    }
}

enum CodexConfigurationKind: String, Codable {
    case chatGPT
    case relay
    case imported

    var title: String {
        switch self {
        case .chatGPT: return "ChatGPT 登录"
        case .relay: return "API 中转"
        case .imported: return "导入配置"
        }
    }
}

struct CodexConfigurationProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: CodexConfigurationKind
    var model: String
    var baseURL: String?
    var updatedAt: Date
}

struct PersistedState: Codable {
    var providers: [ModelProvider]
    var activeProviderID: String
    var activeModel: String
    var openAIModel: String
    var previousModelCatalogPath: String?
    var routerSecret: String?
    var previousNoProxy: String?
    var previousNoProxyCaptured: Bool?
    var configurationMode: ConfigurationMode
    var externalProviderID: String?
    var configurationProfiles: [CodexConfigurationProfile]
    var activeConfigurationProfileID: String?

    init(
        providers: [ModelProvider] = [],
        activeProviderID: String = "openai",
        activeModel: String = "",
        openAIModel: String = "gpt-5.6-sol",
        previousModelCatalogPath: String? = nil,
        routerSecret: String? = nil,
        previousNoProxy: String? = nil,
        previousNoProxyCaptured: Bool? = nil,
        configurationMode: ConfigurationMode = .isolatedProfile,
        externalProviderID: String? = nil,
        configurationProfiles: [CodexConfigurationProfile] = [],
        activeConfigurationProfileID: String? = nil
    ) {
        self.providers = providers
        self.activeProviderID = activeProviderID
        self.activeModel = activeModel
        self.openAIModel = openAIModel
        self.previousModelCatalogPath = previousModelCatalogPath
        self.routerSecret = routerSecret
        self.previousNoProxy = previousNoProxy
        self.previousNoProxyCaptured = previousNoProxyCaptured
        self.configurationMode = configurationMode
        self.externalProviderID = externalProviderID
        self.configurationProfiles = configurationProfiles
        self.activeConfigurationProfileID = activeConfigurationProfileID
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case activeProviderID
        case activeModel
        case openAIModel
        case previousModelCatalogPath
        case routerSecret
        case previousNoProxy
        case previousNoProxyCaptured
        case configurationMode
        case externalProviderID
        case configurationProfiles
        case activeConfigurationProfileID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ModelProvider].self, forKey: .providers) ?? []
        activeProviderID = try container.decodeIfPresent(String.self, forKey: .activeProviderID) ?? "openai"
        activeModel = try container.decodeIfPresent(String.self, forKey: .activeModel) ?? ""
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-5.6-sol"
        previousModelCatalogPath = try container.decodeIfPresent(String.self, forKey: .previousModelCatalogPath)
        routerSecret = try container.decodeIfPresent(String.self, forKey: .routerSecret)
        previousNoProxy = try container.decodeIfPresent(String.self, forKey: .previousNoProxy)
        previousNoProxyCaptured = try container.decodeIfPresent(Bool.self, forKey: .previousNoProxyCaptured)
        configurationMode = try container.decodeIfPresent(ConfigurationMode.self, forKey: .configurationMode)
            ?? .isolatedProfile
        externalProviderID = try container.decodeIfPresent(String.self, forKey: .externalProviderID)
        configurationProfiles = try container.decodeIfPresent([CodexConfigurationProfile].self, forKey: .configurationProfiles) ?? []
        activeConfigurationProfileID = try container.decodeIfPresent(String.self, forKey: .activeConfigurationProfileID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(activeProviderID, forKey: .activeProviderID)
        try container.encode(activeModel, forKey: .activeModel)
        try container.encode(openAIModel, forKey: .openAIModel)
        try container.encodeIfPresent(previousModelCatalogPath, forKey: .previousModelCatalogPath)
        try container.encodeIfPresent(routerSecret, forKey: .routerSecret)
        try container.encodeIfPresent(previousNoProxy, forKey: .previousNoProxy)
        try container.encodeIfPresent(previousNoProxyCaptured, forKey: .previousNoProxyCaptured)
        try container.encode(configurationMode, forKey: .configurationMode)
        try container.encodeIfPresent(externalProviderID, forKey: .externalProviderID)
        try container.encode(configurationProfiles, forKey: .configurationProfiles)
        try container.encodeIfPresent(activeConfigurationProfileID, forKey: .activeConfigurationProfileID)
    }
}

enum ManagerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum KeychainStore {
    // Security.framework can ask for Keychain authorization every time an
    // ad-hoc-signed helper reads an item. Keep secrets only in this process's
    // memory after the first successful unlock. The cache disappears when the
    // panel/router exits and is never serialized.
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]

    static func read(account: String) -> String? {
        cacheLock.lock()
        let cached = cache[account]
        cacheLock.unlock()
        if let cached { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        cacheLock.lock()
        cache[account] = value
        cacheLock.unlock()
        return value
    }

    static func save(_ value: String, account: String) throws {
        guard !value.isEmpty else { throw ManagerError.message("API Key 不能为空") }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ManagerError.message("写入 macOS 钥匙串失败（\(status)）")
        }
        cacheLock.lock()
        cache[account] = value
        cacheLock.unlock()
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        cacheLock.lock()
        cache.removeValue(forKey: account)
        cacheLock.unlock()
    }
}

struct ConfigManager {
    let configURL: URL
    let profileURL: URL
    let dataDirectory: URL
    let keyHelperPath: String
    let managesRuntime: Bool

    init(
        configURL: URL? = nil,
        profileURL: URL? = nil,
        dataDirectory: URL? = nil,
        keyHelperPath: String? = nil,
        managesRuntime: Bool? = nil
    ) {
        let codexHome = codexHomeDirectory()
        let resolvedDataDirectory = dataDirectory
            ?? codexHome.appendingPathComponent("model-manager", isDirectory: true)
        self.configURL = configURL ?? codexHome.appendingPathComponent("config.toml")
        self.profileURL = profileURL
            ?? codexHome.appendingPathComponent(externalProfileFileName)
        self.dataDirectory = resolvedDataDirectory
        self.keyHelperPath = keyHelperPath ?? resolvedDataDirectory
            .appendingPathComponent("runtime/Codex Model Manager.app/Contents/MacOS/CodexModelManager").path
        self.managesRuntime = managesRuntime ?? (configURL == nil && profileURL == nil && dataDirectory == nil)
    }

    func loadState() throws -> PersistedState {
        let url = dataDirectory.appendingPathComponent("state.json")
        let hadStateFile = FileManager.default.fileExists(atPath: url.path)
        let baseText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let legacyBaseConfiguration = containsLegacyBaseConfiguration(baseText)
        var state: PersistedState
        if hadStateFile {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(PersistedState.self, from: Data(contentsOf: url))
        } else {
            state = PersistedState()
        }

        // A previous build stored the provider registry in router-state.json. Recover it
        // before cleaning the old desktop-router settings out of config.toml.
        var stateChanged = false
        if let legacy = try? loadRouterState(), !legacy.providers.isEmpty,
           (!hadStateFile || legacyBaseConfiguration) {
            if state.providers.isEmpty {
                state.providers = legacy.providers
                stateChanged = true
            } else {
                for provider in legacy.providers where !state.providers.contains(where: { $0.id == provider.id }) {
                    state.providers.append(provider)
                    stateChanged = true
                }
            }
            if state.routerSecret == nil, legacy.routerSecret != nil {
                state.routerSecret = legacy.routerSecret
                stateChanged = true
            }
            if state.externalProviderID == nil {
                state.externalProviderID = legacy.externalProviderID
                    ?? legacy.providers.first(where: { $0.canActivate })?.id
                stateChanged = state.externalProviderID != nil
            }
        }

        let active = try readActiveConfiguration()
        if (active.provider == "openai" || active.provider.isEmpty), !active.model.isEmpty,
           state.activeProviderID == "openai" {
            if state.openAIModel.isEmpty || state.openAIModel == "gpt-5.6-sol" {
                state.openAIModel = active.model
                stateChanged = true
            }
            state.activeModel = state.openAIModel
        }

        if state.externalProviderID == nil ||
            !state.providers.contains(where: { $0.id == state.externalProviderID && $0.canActivate }) {
            let replacement = state.providers.first(where: { $0.canActivate })?.id
            if state.externalProviderID != replacement {
                state.externalProviderID = replacement
                stateChanged = true
            }
        }

        if stateChanged {
            try saveState(state)
        }
        return state
    }

    func saveState(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: dataDirectory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(
            to: dataDirectory.appendingPathComponent("state.json"),
            options: .atomic
        )
    }

    func readActiveConfiguration() throws -> (provider: String, model: String) {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return ("openai", "")
        }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        return (topLevelValue("model_provider", in: text) ?? "openai",
                topLevelValue("model", in: text) ?? "")
    }

    private var authURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("auth.json")
    }

    private var configurationProfilesDirectory: URL {
        dataDirectory.appendingPathComponent("configuration-profiles", isDirectory: true)
    }

    private func configurationProfileAuthAccount(_ id: String) -> String {
        "configuration-profile-auth-\(id)"
    }

    func captureCurrentConfiguration(name: String, kind: CodexConfigurationKind) throws -> CodexConfigurationProfile {
        guard FileManager.default.fileExists(atPath: configURL.path),
              FileManager.default.fileExists(atPath: authURL.path) else {
            throw ManagerError.message("当前 config.toml 或 auth.json 不存在")
        }
        return try saveConfigurationPair(
            name: name,
            kind: kind,
            configText: String(contentsOf: configURL, encoding: .utf8),
            authText: String(contentsOf: authURL, encoding: .utf8)
        )
    }

    func importConfigurationPair(name: String, directory: URL) throws -> CodexConfigurationProfile {
        let importedConfig = directory.appendingPathComponent("config.toml")
        let importedAuth = directory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: importedConfig.path),
              FileManager.default.fileExists(atPath: importedAuth.path) else {
            throw ManagerError.message("所选文件夹必须同时包含 config.toml 和 auth.json")
        }
        return try saveConfigurationPair(
            name: name,
            kind: .imported,
            configText: String(contentsOf: importedConfig, encoding: .utf8),
            authText: String(contentsOf: importedAuth, encoding: .utf8)
        )
    }

    func createRelayConfiguration(
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        reviewModel: String,
        modelCatalogPath: String
    ) throws -> CodexConfigurationProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty, !apiKey.isEmpty, !model.isEmpty else {
            throw ManagerError.message("请填写名称、URL、API Key 和模型")
        }
        guard let url = URL(string: trimmedURL), url.scheme == "https" || url.scheme == "http" else {
            throw ManagerError.message("请输入有效的 http(s) API URL")
        }
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        text = removingManagedBlock(from: text)
        text = removingTable("model_providers.cmm_model_router", from: text)
        text = settingTopLevel("model_provider", value: "OpenAI", in: text)
        text = settingTopLevel("model", value: model, in: text)
        text = settingTopLevel("review_model", value: reviewModel.isEmpty ? model : reviewModel, in: text)
        text = settingTopLevelRaw("disable_response_storage", value: "true", in: text)
        text = settingTopLevel("network_access", value: "enabled", in: text)
        text = settingTopLevelRaw("windows_wsl_setup_acknowledged", value: "true", in: text)
        if modelCatalogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = removingTopLevel("model_catalog_json", in: text)
        } else {
            text = settingTopLevel("model_catalog_json", value: modelCatalogPath, in: text)
        }
        text = replacingTable("model_providers.OpenAI", in: text, with: [
            "name = \"OpenAI\"",
            "base_url = \"\(tomlEscape(trimmedURL))\"",
            "wire_api = \"responses\"",
            "requires_openai_auth = true"
        ])
        let authData = try JSONSerialization.data(
            withJSONObject: ["OPENAI_API_KEY": apiKey],
            options: [.prettyPrinted, .sortedKeys]
        )
        return try saveConfigurationPair(
            name: trimmedName,
            kind: .relay,
            configText: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            authText: String(data: authData, encoding: .utf8) ?? "{}"
        )
    }

    func switchConfiguration(to profile: CodexConfigurationProfile) throws {
        let storedConfigURL = configurationProfilesDirectory.appendingPathComponent("\(profile.id).toml")
        guard let storedAuth = KeychainStore.read(account: configurationProfileAuthAccount(profile.id)),
              FileManager.default.fileExists(atPath: storedConfigURL.path) else {
            throw ManagerError.message("配置方案内容或安全凭据不存在")
        }
        let storedConfig = try String(contentsOf: storedConfigURL, encoding: .utf8)
        try validateConfigurationPair(configText: storedConfig, authText: storedAuth)
        let previousConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let previousAuth = (try? String(contentsOf: authURL, encoding: .utf8)) ?? "{}"
        do {
            try backup(previousConfig, label: "switch-config")
            try KeychainStore.save(previousAuth, account: "configuration-switch-last-auth-backup")
            try writeSensitive(storedConfig, to: configURL)
            try writeSensitive(storedAuth, to: authURL)
        } catch {
            try? writeSensitive(previousConfig, to: configURL)
            try? writeSensitive(previousAuth, to: authURL)
            throw error
        }
    }

    func deleteConfigurationProfile(_ profile: CodexConfigurationProfile) {
        KeychainStore.delete(account: configurationProfileAuthAccount(profile.id))
        try? FileManager.default.removeItem(
            at: configurationProfilesDirectory.appendingPathComponent("\(profile.id).toml")
        )
    }

    private func saveConfigurationPair(
        name: String,
        kind: CodexConfigurationKind,
        configText: String,
        authText: String
    ) throws -> CodexConfigurationProfile {
        try validateConfigurationPair(configText: configText, authText: authText)
        let id = "cfg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try FileManager.default.createDirectory(at: configurationProfilesDirectory, withIntermediateDirectories: true)
        try writeSensitive(configText, to: configurationProfilesDirectory.appendingPathComponent("\(id).toml"))
        try KeychainStore.save(authText, account: configurationProfileAuthAccount(id))
        return CodexConfigurationProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名配置" : name,
            kind: kind,
            model: topLevelValue("model", in: configText) ?? "未指定",
            baseURL: tableValue("base_url", table: "model_providers.OpenAI", in: configText),
            updatedAt: Date()
        )
    }

    private func validateConfigurationPair(configText: String, authText: String) throws {
        guard !configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              topLevelValue("model", in: configText) != nil else {
            throw ManagerError.message("config.toml 缺少 model")
        }
        guard let data = authText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ManagerError.message("auth.json 不是有效的 JSON 对象")
        }
    }

    private func writeSensitive(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func syncConfiguration(state: inout PersistedState) throws {
        let importable = state.providers.filter { $0.canActivate }
        let profileImportable = importable.filter { !$0.isAntigravityBridge && $0.wireProtocol.codexCompatible }
        if state.activeProviderID != "openai",
           !importable.contains(where: { $0.id == state.activeProviderID }) {
            state.activeProviderID = "openai"
            state.activeModel = state.openAIModel
        }

        if let active = importable.first(where: { $0.id == state.activeProviderID }) {
            state.externalProviderID = active.id
            state.activeModel = active.model.id
        } else if state.externalProviderID == nil {
            state.externalProviderID = importable.first?.id
        }

        // The external profile is always generated. It is the source of truth for
        // third-party provider settings and is safe to use from `codex --profile config_out`.
        try syncExternalProfile(state: &state, importable: profileImportable)

        // config.toml belongs to the user and is deliberately read-only. All
        // external providers live in config_out and model-manager state; the
        // plugin's MCP delegate calls them without replacing the task provider.
        state.configurationMode = .desktopMenu
        state.routerSecret = nil
    }

    private func backup(_ text: String, label: String) throws {
        guard !text.isEmpty else { return }
        let backupDir = dataDirectory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = backupDir.appendingPathComponent("\(label)-\(formatter.string(from: Date())).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadRouterState() throws -> PersistedState {
        let url = dataDirectory.appendingPathComponent("router-state.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedState.self, from: Data(contentsOf: url))
    }

    private func containsLegacyBaseConfiguration(_ text: String) -> Bool {
        let provider = topLevelValue("model_provider", in: text)
        let catalog = topLevelValue("model_catalog_json", in: text)
        let legacyCatalog = dataDirectory.appendingPathComponent("active-model-catalog.json").path
        return text.contains(managedBlockStart)
            || provider == modelRouterProviderID
            || catalog == legacyCatalog
    }

    private func selectedExternalProvider(
        state: inout PersistedState,
        importable: [ModelProvider]
    ) -> ModelProvider? {
        if let id = state.externalProviderID,
           let selected = importable.first(where: { $0.id == id }) {
            return selected
        }
        if state.activeProviderID != "openai",
           let selected = importable.first(where: { $0.id == state.activeProviderID }) {
            state.externalProviderID = selected.id
            return selected
        }
        let selected = importable.first
        state.externalProviderID = selected?.id
        return selected
    }

    private func syncExternalProfile(state: inout PersistedState, importable: [ModelProvider]) throws {
        let oldText = (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
        var text = removingExternalProfileBlock(from: oldText)
        let selected = selectedExternalProvider(state: &state, importable: importable)
        if let selected {
            if managesRuntime {
                _ = try ensureRuntimeInstalled()
            }
            let catalogPath = dataDirectory.appendingPathComponent("external-model-catalog.json").path
            try writeExternalModelCatalog(for: selected, preferredTemplate: state.openAIModel)
            text = settingTopLevel("model", value: selected.model.id, in: text)
            text = settingTopLevel("model_provider", value: selected.id, in: text)
            text = settingTopLevel("model_catalog_json", value: catalogPath, in: text)
            let block = renderExternalProfileBlock(selected)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text += "\n\n" + block + "\n"
        } else {
            text = removingTopLevel("model", in: text)
            text = removingTopLevel("model_provider", in: text)
            text = removingTopLevel("model_catalog_json", in: text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                text = "# Codex Model Manager external profile\n"
                    + "# Use: codex --profile \(externalProfileName)\n"
            } else {
                text += "\n"
            }
        }
        try writeConfigIfChanged(text, oldText: oldText, to: profileURL, backupLabel: "config-out")
    }

    private func writeExternalModelCatalog(for provider: ModelProvider, preferredTemplate: String) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let baseURL = dataDirectory.appendingPathComponent("base-model-catalog.json")
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try captureBaseModelCatalog(to: baseURL)
        }
        let data = try Data(contentsOf: baseURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty else {
            throw ManagerError.message("无法读取 Codex 基础模型目录")
        }
        let builtInIDs = Set(models.compactMap { $0["slug"] as? String })
        guard !builtInIDs.contains(provider.model.id) else {
            throw ManagerError.message("模型 ID \(provider.model.id) 与 Codex 内置模型重名，请选择其他模型")
        }
        let template = models.first(where: { ($0["slug"] as? String) == preferredTemplate }) ?? models[0]
        var model = template
        model["slug"] = provider.model.id
        model["display_name"] = provider.model.displayName
        model["description"] = "\(provider.name) · 外部 Responses 模型"
        model["priority"] = 10_000
        model["visibility"] = "list"
        model["supported_in_api"] = true
        model["additional_speed_tiers"] = []
        model["service_tiers"] = []
        model["upgrade"] = NSNull()
        model["availability_nux"] = NSNull()
        model["supports_search_tool"] = false
        model["use_responses_lite"] = false
        let rendered = try JSONSerialization.data(
            withJSONObject: ["models": [model]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try rendered.write(
            to: dataDirectory.appendingPathComponent("external-model-catalog.json"),
            options: .atomic
        )
    }

    private func writeConfigIfChanged(_ text: String, oldText: String, to url: URL, backupLabel: String) throws {
        guard text != oldText else { return }
        try writeConfig(text, to: url, backupLabel: backupLabel)
    }

    private func writeConfig(_ text: String, to url: URL, backupLabel: String) throws {
        let oldText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if oldText == text { return }
        try backup(oldText, label: backupLabel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func topLevelValue(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { continue }
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            return unquote(String(trimmed[trimmed.index(after: equal)...])
                .trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private func settingTopLevel(_ key: String, value: String, in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        let rendered = "\(key) = \"\(tomlEscape(value))\""
        let tableIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.count
        for index in 0..<tableIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") {
                lines[index] = rendered
                return lines.joined(separator: "\n")
            }
        }
        lines.insert(rendered, at: tableIndex)
        return lines.joined(separator: "\n")
    }

    private func settingTopLevelRaw(_ key: String, value: String, in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        let rendered = "\(key) = \(value)"
        let tableIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.count
        for index in 0..<tableIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") {
                lines[index] = rendered
                return lines.joined(separator: "\n")
            }
        }
        lines.insert(rendered, at: tableIndex)
        return lines.joined(separator: "\n")
    }

    private func removingTopLevel(_ key: String, in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        let tableIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.count
        for index in (0..<tableIndex).reversed() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") {
                lines.remove(at: index)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func removingTable(_ table: String, from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(table)]" }) else {
            return text
        }
        var end = start + 1
        while end < lines.count {
            if lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            end += 1
        }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    private func replacingTable(_ table: String, in text: String, with body: [String]) -> String {
        let cleaned = removingTable(table, from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned + "\n\n[\(table)]\n" + body.joined(separator: "\n") + "\n"
    }

    private func tableValue(_ key: String, table: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(table)]" }) else {
            return nil
        }
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { continue }
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            return unquote(String(trimmed[trimmed.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func writeActiveModelCatalog(for providers: [ModelProvider], preferredTemplate: String) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let baseURL = dataDirectory.appendingPathComponent("base-model-catalog.json")
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try captureBaseModelCatalog(to: baseURL)
        }

        let data = try Data(contentsOf: baseURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty else {
            throw ManagerError.message("无法读取 Codex 基础模型目录")
        }
        let builtInIDs = Set(models.compactMap { $0["slug"] as? String })
        if let conflict = providers.first(where: { builtInIDs.contains($0.model.id) }) {
            throw ManagerError.message("模型 ID \(conflict.model.id) 与 Codex 内置模型重名，请选择其他模型")
        }
        let template = models.first(where: { ($0["slug"] as? String) == preferredTemplate }) ?? models[0]
        let customModels = providers.enumerated().map { offset, provider -> [String: Any] in
            var model = template
            model["slug"] = provider.model.id
            model["display_name"] = provider.model.displayName
            model["description"] = "\(provider.name) · 自定义 Responses 模型"
            model["priority"] = 10_000 + offset
            model["visibility"] = "list"
            model["supported_in_api"] = true
            model["additional_speed_tiers"] = []
            model["service_tiers"] = []
            model["upgrade"] = NSNull()
            model["availability_nux"] = NSNull()
            model["supports_search_tool"] = false
            model["use_responses_lite"] = false
            return model
        }

        let rendered = try JSONSerialization.data(
            withJSONObject: ["models": models + customModels],
            options: [.prettyPrinted, .sortedKeys]
        )
        try rendered.write(
            to: dataDirectory.appendingPathComponent("active-model-catalog.json"),
            options: .atomic
        )
    }

    private func captureBaseModelCatalog(to destination: URL) throws {
        guard let executable = codexExecutable() else {
            throw ManagerError.message("找不到 codex 命令，无法生成模型目录")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        // The bundled catalog is deterministic and does not require a login or a
        // network request.  A first panel launch should never block on either.
        process.arguments = ["debug", "models", "--bundled"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ManagerError.message("读取 Codex 模型目录失败：\(detail.prefix(160))")
        }
        try data.write(to: destination, options: .atomic)
    }

    private func codexExecutable() -> URL? {
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func removingManagedBlock(from text: String) -> String {
        guard let start = text.range(of: managedBlockStart) else { return text }
        guard let end = text.range(of: managedBlockEnd, range: start.upperBound..<text.endIndex) else {
            return String(text[..<start.lowerBound])
        }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        var result = text
        result.removeSubrange(start.lowerBound..<upper)
        return result
    }

    private func removingExternalProfileBlock(from text: String) -> String {
        guard let start = text.range(of: externalProfileMarkerStart) else { return text }
        guard let end = text.range(of: externalProfileMarkerEnd, range: start.upperBound..<text.endIndex) else {
            return String(text[..<start.lowerBound])
        }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        var result = text
        result.removeSubrange(start.lowerBound..<upper)
        return result
    }

    private func renderExternalProfileBlock(_ provider: ModelProvider) -> String {
        var lines = [externalProfileMarkerStart]
        lines.append("# This file is generated by Codex Model Manager. Edit providers in the panel.")
        lines.append("")
        lines.append("[model_providers.\(provider.id)]")
        lines.append("name = \"\(tomlEscape(provider.name))\"")
        lines.append("base_url = \"\(tomlEscape(provider.baseURL))\"")
        lines.append("wire_api = \"responses\"")
        lines.append("")
        lines.append("[model_providers.\(provider.id).auth]")
        lines.append("command = \"\(tomlEscape(keyHelperPath))\"")
        lines.append("args = [\"--print-key\", \"\(tomlEscape(provider.id))\"]")
        lines.append("timeout_ms = 3000")
        lines.append("")
        lines.append(externalProfileMarkerEnd)
        return lines.joined(separator: "\n")
    }

    private func renderRouterManagedBlock(routerSecret: String?) -> String {
        var lines = [managedBlockStart]
        lines.append("# Only the local bridge lives in config.toml; provider URLs and keys stay outside it.")
        lines.append("")
        lines.append("[model_providers.\(modelRouterProviderID)]")
        lines.append("name = \"Codex Model Router\"")
        lines.append("base_url = \"http://127.0.0.1:\(modelRouterPort)/v1\"")
        lines.append("wire_api = \"responses\"")
        lines.append("requires_openai_auth = true")
        lines.append("supports_websockets = false")
        lines.append("http_headers = { X-Codex-Model-Manager-Token = \"\(tomlEscape(routerSecret ?? ""))\" }")
        lines.append("")
        lines.append(managedBlockEnd)
        return lines.joined(separator: "\n")
    }

    func ensureExternalLauncher() throws -> URL {
        guard let executable = codexExecutable() else {
            throw ManagerError.message("找不到 codex 命令，无法打开外部配置")
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let url = dataDirectory.appendingPathComponent("open-config-out.command")
        let content = "#!/bin/zsh\nset -e\nexec \(shellQuote(executable.path)) --profile \(externalProfileName)\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    var externalProfileCommand: String {
        "codex --profile \(externalProfileName)"
    }

    private var runtimeAppURL: URL {
        dataDirectory.appendingPathComponent("runtime/Codex Model Manager.app", isDirectory: true)
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.codex.model-manager.router.plist")
    }

    private func writeRouterState(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = dataDirectory.appendingPathComponent("router-state.json")
        try encoder.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func ensureRuntimeInstalled() throws -> URL {
        let target = runtimeAppURL
        let executable = target.appendingPathComponent("Contents/MacOS/CodexModelManager")
        let source = Bundle.main.bundleURL.standardizedFileURL
        if source.path == target.standardizedFileURL.path {
            return executable
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent("Codex Model Manager-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ManagerError.message("安装本地模型路由器失败")
        }
        return executable
    }

    private func installRouterLaunchAgent(executable: URL) throws {
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": "local.codex.model-manager.router",
            "ProgramArguments": [executable.path, "--router"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 2,
            "ProcessType": "Background",
            "EnvironmentVariables": ["CODEX_HOME": codexHomeDirectory().path],
            "StandardOutPath": dataDirectory.appendingPathComponent("router.log").path,
            "StandardErrorPath": dataDirectory.appendingPathComponent("router-error.log").path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, launchAgentURL.path])
        guard runLaunchctl(["bootstrap", domain, launchAgentURL.path]) == 0 else {
            throw ManagerError.message("启动本地模型路由器失败")
        }
        _ = runLaunchctl(["kickstart", "-k", "\(domain)/local.codex.model-manager.router"])
    }

    private func stopRouterLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, launchAgentURL.path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private func configureNoProxy(state: inout PersistedState) throws {
        if state.previousNoProxyCaptured != true {
            state.previousNoProxy = launchctlEnvironment("NO_PROXY")
            state.previousNoProxyCaptured = true
        }
        let existing = state.previousNoProxy ?? ""
        var values = existing.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        for local in ["127.0.0.1", "localhost"] where !values.contains(local) {
            values.append(local)
        }
        guard runLaunchctl(["setenv", "NO_PROXY", values.joined(separator: ",")]) == 0 else {
            throw ManagerError.message("无法为 Codex 配置本地路由直连")
        }
    }

    private func restoreNoProxy(state: inout PersistedState) {
        guard state.previousNoProxyCaptured == true else { return }
        if let previous = state.previousNoProxy, !previous.isEmpty {
            _ = runLaunchctl(["setenv", "NO_PROXY", previous])
        } else {
            _ = runLaunchctl(["unsetenv", "NO_PROXY"])
        }
        state.previousNoProxy = nil
        state.previousNoProxyCaptured = nil
    }

    private func launchctlEnvironment(_ name: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", name]
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ProviderAPIClient {
    func fetchModels(baseURL: String, key: String, protocolType: ProviderWireProtocol) async throws -> [String] {
        var request: URLRequest
        switch protocolType {
        case .responses, .chatCompletions:
            request = URLRequest(url: try endpoint(baseURL, suffix: "models"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            var components = URLComponents(url: try endpoint(baseURL, suffix: "models"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "key", value: key)]
            request = URLRequest(url: components.url!)
        }
        request.timeoutInterval = 20
        let data = try await perform(request)
        let object = try JSONSerialization.jsonObject(with: data)
        var result: [String] = []
        if let dictionary = object as? [String: Any],
           let rows = dictionary["data"] as? [[String: Any]] {
            result = rows.compactMap { $0["id"] as? String }
        } else if let dictionary = object as? [String: Any],
                  let rows = dictionary["models"] as? [[String: Any]] {
            result = rows.compactMap { row in
                (row["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            }
        }
        result = Array(Set(result.filter { !$0.isEmpty })).sorted()
        guard !result.isEmpty else {
            throw ManagerError.message("模型接口可访问，但没有识别到模型 ID；可手动填写")
        }
        return result
    }

    func test(baseURL: String, key: String, model: String, protocolType: ProviderWireProtocol) async throws {
        let url: URL
        var body: [String: Any]
        switch protocolType {
        case .responses:
            url = try endpoint(baseURL, suffix: "responses")
            body = [
                "model": model,
                "input": "Reply with OK only.",
                "max_output_tokens": 16,
                "stream": false
            ]
        case .chatCompletions:
            url = try endpoint(baseURL, suffix: "chat/completions")
            body = [
                "model": model,
                "messages": [["role": "user", "content": "Reply with OK only."]],
                "max_tokens": 16,
                "stream": false
            ]
        case .gemini:
            var components = URLComponents(
                url: try endpoint(baseURL, suffix: "models/\(model):generateContent"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "key", value: key)]
            url = components.url!
            body = ["contents": [["parts": [["text": "Reply with OK only."]]]]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if protocolType != .gemini {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func endpoint(_ baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/" + suffix),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ManagerError.message("请输入有效的 http(s) API Base URL")
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ManagerError.message("厂商返回了无效的 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(220) ?? ""
                throw ManagerError.message("API 请求失败：HTTP \(http.statusCode) \(detail)")
            }
            return data
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError.message("无法连接厂商 API：\(error.localizedDescription)")
        }
    }
}

@MainActor
final class ManagerStore: ObservableObject {
    @Published private(set) var state: PersistedState
    @Published var selectedProviderID: String?
    @Published var message = "就绪"
    @Published var showingError = false

    private let config = ConfigManager()

    init() {
        do {
            state = try config.loadState()
            // Materialize only the independent external profile. The user's main
            // config.toml is deliberately never rewritten by this application.
            try config.syncConfiguration(state: &state)
            if state.configurationProfiles.isEmpty {
                if let authText = try? String(contentsOf: codexHomeDirectory().appendingPathComponent("auth.json"), encoding: .utf8),
                   let authObject = try? JSONSerialization.jsonObject(with: Data(authText.utf8)) as? [String: Any],
                   let current = try? config.captureCurrentConfiguration(
                        name: "当前配置备份",
                        kind: authObject["auth_mode"] as? String == "chatgpt" ? .chatGPT : .imported
                   ) {
                    state.configurationProfiles.append(current)
                    state.activeConfigurationProfileID = current.id
                }
                let legacyDirectory = codexHomeDirectory().appendingPathComponent("text", isDirectory: true)
                if FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("config.toml").path),
                   FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("auth.json").path),
                   let imported = try? config.importConfigurationPair(name: "text 中转配置", directory: legacyDirectory) {
                    state.configurationProfiles.append(imported)
                }
            }
            try config.saveState(state)
            selectedProviderID = state.providers.first?.id
            message = "普通模型管理不改主配置；配置方案可成对切换 config.toml 与 auth.json"
        } catch {
            state = PersistedState()
            message = error.localizedDescription
            showingError = true
        }
    }

    var selectedProvider: ModelProvider? {
        guard let id = selectedProviderID else { return nil }
        return state.providers.first(where: { $0.id == id })
    }

    var activeTitle: String {
        if state.activeProviderID == "openai" {
            return "本地 GPT · \(state.openAIModel)"
        }
        guard let provider = state.providers.first(where: { $0.id == state.activeProviderID }) else {
            return "本地 GPT · \(state.openAIModel)"
        }
        return "默认委派 · \(provider.name) · \(provider.model.displayName)"
    }

    func upsert(_ provider: ModelProvider, apiKey: String, activateAfterSave: Bool) throws {
        try KeychainStore.save(apiKey, account: provider.id)
        if let index = state.providers.firstIndex(where: { $0.id == provider.id }) {
            state.providers[index] = provider
        } else {
            state.providers.append(provider)
        }
        selectedProviderID = provider.id
        if provider.canActivate {
            state.externalProviderID = provider.id
            if activateAfterSave || state.activeProviderID == provider.id {
                state.activeProviderID = provider.id
                state.activeModel = provider.model.id
            }
        }
        try persistAndSync()
        if state.activeProviderID == provider.id {
            message = "已添加 \(provider.model.id) 并设为默认委派模型"
        } else {
            message = "已添加 \(provider.model.id)；可通过 delegate_task 委派"
        }
    }

    func setProviderEnabled(_ enabled: Bool, id: String) {
        mutate(id: id) { $0.enabled = enabled }
    }

    func setModelEnabled(_ enabled: Bool, id: String) {
        mutate(id: id) { $0.model.enabled = enabled }
    }

    func activateOpenAI() {
        state.activeProviderID = "openai"
        state.activeModel = state.openAIModel
        commit("已清除默认委派；本地 GPT 与外部模型配置均未改动")
    }

    func activate(_ provider: ModelProvider) {
        guard provider.canActivate else { return }
        if provider.isAntigravityBridge {
            state.configurationMode = .desktopMenu
        }
        state.externalProviderID = provider.id
        state.activeProviderID = provider.id
        state.activeModel = provider.model.id
        commit("已将 \(provider.name) · \(provider.model.id) 设为默认委派模型")
    }

    func importAntigravity(models: [String]) {
        let uniqueModels = Array(Set(models)).sorted()
        guard !uniqueModels.isEmpty else { return }
        let now = Date()
        for model in uniqueModels {
            let suffix = model.lowercased().map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
            let id = "cmm_antigravity_\(String(suffix))"
            let family: String
            if model.hasPrefix("gemini-") {
                family = "Gemini"
            } else if model.hasPrefix("claude-") {
                family = "Claude"
            } else {
                family = "GPT-OSS"
            }
            let provider = ModelProvider(
                id: id,
                name: "Antigravity · \(family)",
                baseURL: "antigravity://local",
                wireProtocol: .responses,
                model: ManagedModel(id: model, displayName: model, enabled: true),
                enabled: true,
                verifiedAt: now
            )
            if let index = state.providers.firstIndex(where: { $0.id == id }) {
                state.providers[index] = provider
            } else {
                state.providers.append(provider)
            }
        }
        state.configurationMode = .desktopMenu
        let selectedSuffix = String(uniqueModels[0].lowercased().map {
            $0.isLetter || $0.isNumber ? $0 : "_"
        })
        selectedProviderID = "cmm_antigravity_\(selectedSuffix)"
        commit("已将 \(uniqueModels.count) 个 Antigravity 模型加入委派列表")
    }

    func deleteProvider(_ provider: ModelProvider) {
        KeychainStore.delete(account: provider.id)
        state.providers.removeAll { $0.id == provider.id }
        if state.externalProviderID == provider.id {
            state.externalProviderID = state.providers.first(where: { $0.canActivate })?.id
        }
        if state.activeProviderID == provider.id {
            state.activeProviderID = "openai"
            state.activeModel = state.openAIModel
        }
        selectedProviderID = state.providers.first?.id
        commit("已删除 \(provider.name)")
    }

    func setConfigurationMode(_ mode: ConfigurationMode) {
        state.configurationMode = .desktopMenu
        commit("已启用安全委派；只有配置方案的一键切换会替换主配置")
    }

    func openExternalProfile() {
        do {
            let launcher = try config.ensureExternalLauncher()
            guard NSWorkspace.shared.open(launcher) else {
                throw ManagerError.message("无法打开外部配置终端")
            }
            message = "已打开外部 Codex（config_out）"
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    func copyExternalProfileCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.externalProfileCommand, forType: .string)
        message = "已复制：\(config.externalProfileCommand)"
    }

    var externalProfilePath: String {
        config.profileURL.path
    }

    var localConfigPath: String {
        config.configURL.path
    }

    var externalProfileCommand: String {
        config.externalProfileCommand
    }

    func captureCurrentConfiguration(name: String) {
        do {
            let authText = try String(contentsOf: codexHomeDirectory().appendingPathComponent("auth.json"), encoding: .utf8)
            let authObject = try JSONSerialization.jsonObject(with: Data(authText.utf8)) as? [String: Any]
            let kind: CodexConfigurationKind = authObject?["auth_mode"] as? String == "chatgpt" ? .chatGPT : .imported
            let profile = try config.captureCurrentConfiguration(name: name, kind: kind)
            state.configurationProfiles.append(profile)
            state.activeConfigurationProfileID = profile.id
            try config.saveState(state)
            message = "已保存当前 config.toml 与 auth.json"
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    func createRelayConfiguration(
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        reviewModel: String,
        modelCatalogPath: String
    ) -> Bool {
        do {
            let profile = try config.createRelayConfiguration(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                reviewModel: reviewModel,
                modelCatalogPath: modelCatalogPath
            )
            state.configurationProfiles.append(profile)
            try config.saveState(state)
            message = "已保存中转配置；点击切换后生效"
            return true
        } catch {
            message = error.localizedDescription
            showingError = true
            return false
        }
    }

    func importConfigurationDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let profile = try config.importConfigurationPair(name: directory.lastPathComponent + " 配置", directory: directory)
            state.configurationProfiles.append(profile)
            try config.saveState(state)
            message = "已导入 \(profile.name)"
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    func switchConfiguration(_ profile: CodexConfigurationProfile) {
        do {
            try config.switchConfiguration(to: profile)
            state.activeConfigurationProfileID = profile.id
            try config.saveState(state)
            message = "已切换到 \(profile.name)；完全退出并重新打开 Codex 后生效"
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    func deleteConfiguration(_ profile: CodexConfigurationProfile) {
        config.deleteConfigurationProfile(profile)
        state.configurationProfiles.removeAll { $0.id == profile.id }
        if state.activeConfigurationProfileID == profile.id {
            state.activeConfigurationProfileID = nil
        }
        do {
            try config.saveState(state)
            message = "已删除配置方案 \(profile.name)"
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    private func mutate(id: String, action: (inout ModelProvider) -> Void) {
        guard let index = state.providers.firstIndex(where: { $0.id == id }) else { return }
        action(&state.providers[index])
        commit("配置已更新")
    }

    private func commit(_ success: String) {
        do {
            try persistAndSync()
            message = success
        } catch {
            message = error.localizedDescription
            showingError = true
        }
    }

    private func persistAndSync() throws {
        try config.syncConfiguration(state: &state)
        try config.saveState(state)
    }
}

struct ProviderEditor: View {
    let existing: ModelProvider?
    let onSave: (ModelProvider, String, Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var protocolType: ProviderWireProtocol
    @State private var apiKey = ""
    @State private var candidates: [String]
    @State private var selectedModel: String
    @State private var displayName: String
    @State private var activateAfterSave: Bool
    @State private var isWorking = false
    @State private var status = "先获取模型，再测试连接"
    @State private var errorText: String?

    private let client = ProviderAPIClient()

    init(existing: ModelProvider?, onSave: @escaping (ModelProvider, String, Bool) throws -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? "")
        _protocolType = State(initialValue: existing?.wireProtocol ?? .responses)
        let modelID = existing?.model.id ?? ""
        _candidates = State(initialValue: modelID.isEmpty ? [] : [modelID])
        _selectedModel = State(initialValue: modelID)
        _displayName = State(initialValue: existing?.model.displayName ?? modelID)
        _activateAfterSave = State(initialValue: existing == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(existing == nil ? "添加厂商" : "编辑厂商")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(protocolType.note)
                    .font(.caption)
                    .foregroundStyle(Color.green)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("厂商")
                    TextField("例如 DeepSeek Gateway", text: $name)
                }
                GridRow {
                    Text("API 地址")
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("API Key")
                    SecureField(existing == nil ? "必填" : "留空则保留原 Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("协议")
                    Picker("", selection: $protocolType) {
                        ForEach(ProviderWireProtocol.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                }
            }

            Divider()

            HStack {
                Text("模型（每个厂商只保留一个）")
                    .font(.headline)
                Spacer()
                Button("获取列表") { Task { await fetchModels() } }
                    .disabled(isWorking || baseURL.isEmpty)
            }

            if candidates.isEmpty {
                TextField("手动填写模型 ID", text: $selectedModel)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("模型", selection: $selectedModel) {
                    ForEach(candidates, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            TextField("显示名称（可选）", text: $displayName)
                .textFieldStyle(.roundedBorder)

            Toggle("保存后设为默认委派模型", isOn: $activateAfterSave)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            } else {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(activateAfterSave ? "测试、保存并设为默认委派" : "测试并保存") {
                    Task { await verifyAndSave() }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty || selectedModel.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func resolvedKey() throws -> String {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        if let id = existing?.id, let saved = KeychainStore.read(account: id) { return saved }
        throw ManagerError.message("请输入 API Key")
    }

    @MainActor
    private func fetchModels() async {
        isWorking = true
        errorText = nil
        status = "正在获取模型列表…"
        defer { isWorking = false }
        do {
            let key = try resolvedKey()
            candidates = try await client.fetchModels(
                baseURL: baseURL,
                key: key,
                protocolType: protocolType
            )
            if !candidates.contains(selectedModel) { selectedModel = candidates[0] }
            if displayName.isEmpty { displayName = selectedModel }
            status = "已获取 \(candidates.count) 个模型，请单选一个"
        } catch {
            errorText = error.localizedDescription + "。你仍可手动填写模型 ID。"
            candidates = []
        }
    }

    @MainActor
    private func verifyAndSave() async {
        isWorking = true
        errorText = nil
        status = "正在发送最小测试请求…"
        defer { isWorking = false }
        do {
            let key = try resolvedKey()
            try await client.test(
                baseURL: baseURL,
                key: key,
                model: selectedModel,
                protocolType: protocolType
            )
            let provider = ModelProvider(
                id: existing?.id ?? "cmm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                wireProtocol: protocolType,
                model: ManagedModel(
                    id: selectedModel.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: displayName.isEmpty ? selectedModel : displayName,
                    enabled: existing?.model.enabled ?? true
                ),
                enabled: existing?.enabled ?? true,
                verifiedAt: Date()
            )
            try onSave(provider, key, activateAfterSave)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ProviderDetail: View {
    @ObservedObject var store: ManagerStore
    let provider: ModelProvider
    let onEdit: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name).font(.title2.weight(.semibold))
                    Text(provider.isAntigravityBridge ? "本地 agy CLI 桥接" : provider.baseURL)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !provider.isAntigravityBridge {
                    Button("编辑", action: onEdit)
                }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }

            HStack {
                Label(
                    provider.isAntigravityBridge ? "Antigravity CLI → Responses" : provider.wireProtocol.title,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                Spacer()
                Toggle("启用厂商", isOn: Binding(
                    get: { provider.enabled },
                    set: { store.setProviderEnabled($0, id: provider.id) }
                ))
                .toggleStyle(.switch)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.model.displayName).font(.headline)
                        Text(provider.model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用模型", isOn: Binding(
                        get: { provider.model.enabled },
                        set: { store.setModelEnabled($0, id: provider.id) }
                    ))
                    .toggleStyle(.switch)
                }

                Divider()

                HStack {
                    if provider.verifiedAt != nil {
                        if provider.isAntigravityBridge {
                            Label("模型已验证 · 使用 Antigravity 登录", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(
                                "API 已验证 · Keychain 已保存",
                                systemImage: "checkmark.seal.fill"
                            )
                            .foregroundStyle(Color.green)
                        }
                    }
                    Spacer()
                    let isActive = store.state.activeProviderID == provider.id
                    Button(isActive ? "默认委派" : "设为默认委派") {
                        store.activate(provider)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!provider.canActivate || isActive)
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))

            if provider.isAntigravityBridge {
                Label(
                    "Antigravity 作为文本推理端运行；文件、终端和浏览器等本地工具仍由当前 Codex 任务执行。",
                    systemImage: "text.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label(
                "当前 Codex 始终保持 GPT 和本地工具；delegate_task 只把你明确委派的文字任务发给这个模型，再把结果返回当前任务。",
                systemImage: "arrow.triangle.branch"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("每个厂商只保留一个模型。委派配置独立保存；只有在配置方案中点击一键切换才会替换主配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .alert("删除 \(provider.name)？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.deleteProvider(provider) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除厂商、模型、独立外部配置和钥匙串中的 API Key；config.toml 不受影响。")
        }
    }
}

struct AntigravityPanel: View {
    @ObservedObject var store: ManagerStore
    @State private var snapshot = AntigravitySnapshot()
    @State private var selectedModels = Set<String>()
    @State private var isWorking = false
    @State private var detail = ""

    private var modelGroups: [(String, [String])] {
        let groups = Dictionary(grouping: snapshot.models) { model -> String in
            if model.hasPrefix("gemini-") { return "Gemini" }
            if model.hasPrefix("claude-") { return "Claude" }
            return "GPT-OSS"
        }
        return ["Gemini", "Claude", "GPT-OSS"].compactMap { key in
            groups[key].map { (key, $0) }
        }
    }

    private var importedModels: Set<String> {
        Set(store.state.providers.filter(\.isAntigravityBridge).map(\.model.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Antigravity 账号", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                if let version = snapshot.version {
                    Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(snapshot.installed ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(snapshot.message).font(.caption)
                Spacer()
                Button(snapshot.installed ? "重新检测" : "一键安装") {
                    installOrRefresh()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                if let path = snapshot.executablePath {
                    Button("打开登录") { openLogin(path: path) }
                        .disabled(isWorking)
                }
            }

            if snapshot.installed {
                HStack {
                    Text("可用模型").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("查询额度") { queryUsage() }.disabled(isWorking)
                    Button("刷新模型") { refresh() }.disabled(isWorking)
                }
                if modelGroups.isEmpty {
                    Text("尚未读取到模型；请先登录 Antigravity，再刷新模型。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(modelGroups, id: \.0) { group, models in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                                ForEach(models, id: \.self) { model in
                                    HStack(spacing: 5) {
                                        Toggle(model, isOn: Binding(
                                            get: { selectedModels.contains(model) },
                                            set: { enabled in
                                                if enabled { selectedModels.insert(model) }
                                                else { selectedModels.remove(model) }
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .font(.caption)
                                        if importedModels.contains(model) {
                                            Text("已导入")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Button(importedModels.isDisjoint(with: selectedModels)
                            ? "测试并加入委派"
                            : "重新测试并同步委派") {
                            testAndImport()
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || selectedModels.isEmpty)
                        Text("通过测试后加入 delegate_task 可用模型")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let usage = snapshot.usageReport, !usage.isEmpty {
                    Text(usage)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { refresh() }
    }

    private func refresh() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AntigravityCLI.detect()
            }.value
            snapshot = result
            selectedModels = selectedModels.intersection(Set(result.models))
            isWorking = false
        }
    }

    private func installOrRefresh() {
        guard !isWorking else { return }
        isWorking = true
        detail = "正在下载并运行官方安装脚本…"
        let alreadyInstalled = snapshot.installed
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                alreadyInstalled ? AntigravityCLI.detect() : AntigravityCLI.install()
            }.value
            snapshot = result
            isWorking = false
            detail = result.message
        }
    }

    private func queryUsage() {
        guard let path = snapshot.executablePath, !isWorking else { return }
        isWorking = true
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                AntigravityCLI.usage(executablePath: path)
            }.value
            snapshot.usageReport = report.isEmpty ? "未返回额度信息；请在 Antigravity 中查看 /usage" : report
            isWorking = false
        }
    }

    private func testAndImport() {
        guard let path = snapshot.executablePath, !isWorking else { return }
        isWorking = true
        let models = selectedModels.sorted()
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: models.map { model in
                    let result = AntigravityCLI.test(executablePath: path, model: model)
                    return (model, result.status)
                })
            }.value
            let passed = models.filter { results[$0] == 0 }
            if !passed.isEmpty {
                store.importAntigravity(models: passed)
            }
            detail = models.map { model in
                "\(model): \(results[model] == 0 ? "已导入" : "测试失败")"
            }.joined(separator: "；")
            isWorking = false
        }
    }

    private func openLogin(path: String) {
        do {
            let script = try AntigravityCLI.openLoginScript(
                executablePath: path,
                directory: codexHomeDirectory().appendingPathComponent("model-manager", isDirectory: true)
            )
            guard NSWorkspace.shared.open(script) else {
                detail = "无法打开登录终端"
                return
            }
            detail = "已打开 Antigravity 登录终端；登录后点击“刷新模型”"
        } catch {
            detail = error.localizedDescription
        }
    }
}

struct ConfigurationProfilesPanel: View {
    @ObservedObject var store: ManagerStore
    @Environment(\.dismiss) private var dismiss
    @State private var snapshotName = "我的当前配置"
    @State private var relayName = ""
    @State private var relayURL = ""
    @State private var relayKey = ""
    @State private var relayModel = "gpt-5.5"
    @State private var reviewModel = "gpt-5.5"
    @State private var catalogPath = "~/.codex/codex-models.json"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex 配置方案").font(.title2.weight(.semibold))
                    Text("每个方案成对保存 config.toml 与 auth.json；密钥和登录令牌保存在系统钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("当前配置名称", text: $snapshotName)
                        Button("保存当前") { store.captureCurrentConfiguration(name: snapshotName) }
                    }
                    Button("导入包含 config.toml 和 auth.json 的文件夹") {
                        store.importConfigurationDirectory()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                    Text("已保存方案").font(.headline)
                    List {
                        ForEach(store.state.configurationProfiles) { profile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name).font(.headline)
                                        Text("\(profile.kind.title) · \(profile.model)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let url = profile.baseURL {
                                            Text(url).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if store.state.activeConfigurationProfileID == profile.id {
                                        Text("当前").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                HStack {
                                    Button("一键切换") { store.switchConfiguration(profile) }
                                        .buttonStyle(.borderedProminent)
                                    Button("删除", role: .destructive) { store.deleteConfiguration(profile) }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(minWidth: 330)

                Form {
                    Section("新建 API 中转配置") {
                        TextField("方案名称", text: $relayName)
                        TextField("API URL，例如 https://194834.xyz", text: $relayURL)
                        SecureField("API Key", text: $relayKey)
                        TextField("主模型", text: $relayModel)
                        TextField("Review 模型", text: $reviewModel)
                        TextField("模型目录路径（可选）", text: $catalogPath)
                    }
                    Section {
                        Button("保存中转配置") {
                            if store.createRelayConfiguration(
                                name: relayName,
                                baseURL: relayURL,
                                apiKey: relayKey,
                                model: relayModel,
                                reviewModel: reviewModel,
                                modelCatalogPath: catalogPath
                            ) {
                                relayKey = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Section {
                        Text("切换会先备份当前配置，再同时替换两份文件。Codex 在启动时读取配置，因此切换后需要完全退出并重新打开 Codex。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 390)
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 560)
    }
}

struct ContentView: View {
    @StateObject private var store = ManagerStore()
    @State private var showingEditor = false
    @State private var editingProvider: ModelProvider?
    @State private var showingAntigravityPanel = false
    @State private var showingConfigurationProfiles = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全委派：\(store.activeTitle)").font(.headline)
                        Text("当前 Codex 保留 GPT 与本地工具，外部模型只处理委派的子任务").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("配置方案") { showingConfigurationProfiles = true }
                    Button("清除默认委派") { store.activateOpenAI() }
                        .disabled(store.state.activeProviderID == "openai")
                    Button {
                        editingProvider = nil
                        showingEditor = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    Label("本地 GPT", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold))
                    Text(store.localConfigPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Label("外部 \(externalProfileName)", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.semibold))
                    Text(store.externalProfilePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Label("安全委派", systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.semibold))
                    Text("外部委派独立保存；主配置仅在点击一键切换时成对替换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("通过 delegate_task 调用")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Button("打开外部 Codex") { store.openExternalProfile() }
                    Button("复制命令") { store.copyExternalProfileCommand() }
                }
            }
            .padding(14)

            HStack(spacing: 10) {
                Label("Antigravity 账号", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text("安装 CLI、登录、同步模型与额度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("管理账号") { showingAntigravityPanel = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            HSplitView {
                List(selection: $store.selectedProviderID) {
                    ForEach(store.state.providers) { provider in
                        HStack {
                            Circle()
                                .fill(provider.canActivate ? Color.green : Color.gray)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                Text(provider.model.displayName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.state.activeProviderID == provider.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        .tag(provider.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 210, idealWidth: 230)

                Group {
                    if let provider = store.selectedProvider {
                        ProviderDetail(store: store, provider: provider) {
                            editingProvider = provider
                            showingEditor = true
                        }
                    } else {
                        ContentUnavailableView(
                            "还没有自定义厂商",
                            systemImage: "square.stack.3d.up.slash",
                            description: Text("添加厂商，拉取一个模型并通过 API 测试后再导入。")
                        )
                    }
                }
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Text(store.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("Keychain · config.toml + auth.json 配置方案").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showingEditor) {
            ProviderEditor(existing: editingProvider) { provider, key, activate in
                try store.upsert(provider, apiKey: key, activateAfterSave: activate)
            }
        }
        .sheet(isPresented: $showingAntigravityPanel) {
            AntigravityPanel(store: store)
                .frame(minWidth: 620, minHeight: 500)
                .padding(6)
        }
        .sheet(isPresented: $showingConfigurationProfiles) {
            ConfigurationProfilesPanel(store: store)
        }
        .alert("操作失败", isPresented: $store.showingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.message)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SelfTest {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-model-manager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        let profileURL = root.appendingPathComponent("config_out.config.toml")
        let dataURL = root.appendingPathComponent("data", isDirectory: true)
        try "model = \"gpt-test\"\n\n[features]\nweb_search = true\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "{\"OPENAI_API_KEY\":\"original-test-key\"}\n"
            .write(to: root.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        let catalogFixture: [String: Any] = [
            "models": [[
                "slug": "gpt-test",
                "display_name": "GPT Test",
                "description": "fixture",
                "priority": 1,
                "visibility": "list",
                "supported_in_api": true,
                "additional_speed_tiers": [],
                "service_tiers": [],
                "upgrade": NSNull(),
                "availability_nux": NSNull(),
                "supports_search_tool": false,
                "use_responses_lite": false
            ]]
        ]
        try JSONSerialization.data(withJSONObject: catalogFixture, options: [.sortedKeys])
            .write(to: dataURL.appendingPathComponent("base-model-catalog.json"), options: .atomic)

        let provider = ModelProvider(
            id: "cmm_selftest",
            name: "Self Test",
            baseURL: "https://example.invalid/v1",
            wireProtocol: .responses,
            model: ManagedModel(id: "test-model", displayName: "Test Model", enabled: true),
            enabled: true,
            verifiedAt: Date()
        )
        let geminiProvider = ModelProvider(
            id: "cmm_gemini_selftest",
            name: "Gemini Relay",
            baseURL: "https://gemini.example.invalid/v1",
            wireProtocol: .responses,
            model: ManagedModel(id: "gemini-test", displayName: "Gemini Test", enabled: true),
            enabled: true,
            verifiedAt: Date()
        )
        let mixedTools: [String: Any] = [
            "model": "gemini-test",
            "tools": [
                ["type": "web_search_preview"],
                ["type": "function", "name": "echo"]
            ]
        ]
        let mixedData = try JSONSerialization.data(withJSONObject: mixedTools)
        let sanitized = LocalModelRouter.sanitizedBody(mixedData, for: geminiProvider)
        guard let sanitizedObject = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let sanitizedTools = sanitizedObject["tools"] as? [[String: Any]],
              sanitizedTools.count == 1,
              sanitizedTools[0]["type"] as? String == "function" else {
            throw ManagerError.message("Gemini 工具兼容自检失败")
        }
        var state = PersistedState(
            providers: [provider],
            activeProviderID: provider.id,
            activeModel: provider.model.id,
            openAIModel: "gpt-test"
        )
        let manager = ConfigManager(
            configURL: configURL,
            profileURL: profileURL,
            dataDirectory: dataURL,
            keyHelperPath: "/tmp/key-helper",
            managesRuntime: false
        )

        let originalConfig = "model = \"gpt-test\"\n\n[features]\nweb_search = true\n"

        // Every synchronization path must leave config.toml byte-for-byte unchanged.
        try manager.syncConfiguration(state: &state)
        var baseRendered = try String(contentsOf: configURL, encoding: .utf8)
        var profileRendered = try String(contentsOf: profileURL, encoding: .utf8)
        guard baseRendered == originalConfig,
              profileRendered.contains("model = \"test-model\""),
              profileRendered.contains("model_provider = \"cmm_selftest\""),
              profileRendered.contains("model_catalog_json = \"\(dataURL.path)/external-model-catalog.json\""),
              profileRendered.contains("[model_providers.cmm_selftest.auth]"),
              profileRendered.contains("args = [\"--print-key\", \"cmm_selftest\"]"),
              FileManager.default.fileExists(atPath: dataURL.appendingPathComponent("external-model-catalog.json").path),
              !baseRendered.contains(modelRouterProviderID) else {
            throw ManagerError.message("只读主配置自检失败")
        }

        state.providers[0].model.enabled = false
        try manager.syncConfiguration(state: &state)
        baseRendered = try String(contentsOf: configURL, encoding: .utf8)
        profileRendered = try String(contentsOf: profileURL, encoding: .utf8)
        guard state.activeProviderID == "openai",
              baseRendered == originalConfig,
              !profileRendered.contains("model_provider = \"cmm_selftest\""),
              !profileRendered.contains("[model_providers.cmm_selftest]") else {
            throw ManagerError.message("禁用回退自检失败")
        }

        state.providers[0].model.enabled = true
        state.activeProviderID = provider.id
        state.activeModel = provider.model.id
        state.configurationMode = .desktopMenu
        try manager.syncConfiguration(state: &state)
        baseRendered = try String(contentsOf: configURL, encoding: .utf8)
        guard baseRendered == originalConfig,
              !baseRendered.contains(modelRouterProviderID) else {
            throw ManagerError.message("安全委派主配置只读自检失败")
        }

        // Reopening the panel must also preserve the user's main configuration.
        try manager.saveState(state)
        var reopened = try manager.loadState()
        guard reopened.configurationMode == .desktopMenu else {
            throw ManagerError.message("安全委派模式重启后状态丢失")
        }
        try manager.syncConfiguration(state: &reopened)
        baseRendered = try String(contentsOf: configURL, encoding: .utf8)
        guard baseRendered == originalConfig else {
            throw ManagerError.message("重启后主配置发生变化")
        }

        state = reopened
        state.configurationMode = .isolatedProfile
        try manager.syncConfiguration(state: &state)
        baseRendered = try String(contentsOf: configURL, encoding: .utf8)
        guard state.configurationMode == .desktopMenu,
              baseRendered == originalConfig,
              !baseRendered.contains(modelRouterProviderID) else {
            throw ManagerError.message("旧模式迁移只读自检失败")
        }
        try manager.saveState(state)
        _ = try manager.loadState()

        let relayProfile = try manager.createRelayConfiguration(
            name: "Relay Test",
            baseURL: "https://relay.example.invalid/v1",
            apiKey: "relay-test-key",
            model: "relay-model",
            reviewModel: "relay-review",
            modelCatalogPath: "~/.codex/codex-models.json"
        )
        defer {
            manager.deleteConfigurationProfile(relayProfile)
            KeychainStore.delete(account: "configuration-switch-last-auth-backup")
        }
        try manager.switchConfiguration(to: relayProfile)
        let switchedConfig = try String(contentsOf: configURL, encoding: .utf8)
        let switchedAuth = try String(contentsOf: root.appendingPathComponent("auth.json"), encoding: .utf8)
        guard switchedConfig.contains("model_provider = \"OpenAI\""),
              switchedConfig.contains("model = \"relay-model\""),
              switchedConfig.contains("review_model = \"relay-review\""),
              switchedConfig.contains("base_url = \"https://relay.example.invalid/v1\""),
              !switchedConfig.contains(modelRouterProviderID),
              switchedAuth.contains("relay-test-key") else {
            throw ManagerError.message("成对配置切换自检失败")
        }
    }
}

@main
struct CodexModelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--print-key" {
            if let key = KeychainStore.read(account: CommandLine.arguments[2]), !key.isEmpty {
                print(key)
                exit(0)
            }
            fputs("API key not found in Keychain\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--router" {
            do {
                try LocalModelRouter().run()
            } catch {
                fputs("Router failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfTest.run()
                print("Codex Model Manager self-test passed")
                exit(0)
            } catch {
                fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--sync" {
            do {
                let manager = ConfigManager()
                var state = try manager.loadState()
                try manager.syncConfiguration(state: &state)
                try manager.saveState(state)
                print("Codex Model Manager configuration synchronized")
                exit(0)
            } catch {
                fputs("Sync failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Codex 模型管理器") {
            ContentView()
        }
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)
    }
}
