import Foundation
import Darwin

private let routerHost = "127.0.0.1"
let modelRouterPort: UInt16 = 58435
let modelRouterProviderID = "cmm_model_router"

private struct RouterRequest {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

private struct AntigravityEnvelope: Decodable {
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
    }

    let status: String?
    let response: String
    let usage: Usage?
}

private final class StreamingProxyDelegate: NSObject, URLSessionDataDelegate {
    private let clientFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private var sentHeaders = false
    private var writeFailed = false

    init(clientFD: Int32) {
        self.clientFD = clientFD
    }

    func wait() {
        done.wait()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            sendError(status: 502, message: "Invalid upstream response")
            completionHandler(.cancel)
            return
        }

        var lines = ["HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
        for (rawName, rawValue) in http.allHeaderFields {
            guard let name = rawName as? String else { continue }
            let lower = name.lowercased()
            if ["content-length", "transfer-encoding", "connection", "content-encoding"].contains(lower) {
                continue
            }
            lines.append("\(name): \(rawValue)")
        }
        lines.append("Transfer-Encoding: chunked")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        sentHeaders = writeAll(Data(lines.joined(separator: "\r\n").utf8))
        writeFailed = !sentHeaders
        completionHandler(writeFailed ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard sentHeaders, !writeFailed else { return }
        let prefix = Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8)
        writeFailed = !writeAll(prefix) || !writeAll(data) || !writeAll(Data("\r\n".utf8))
        if writeFailed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !sentHeaders {
            sendError(status: 502, message: error?.localizedDescription ?? "Upstream request failed")
        } else if !writeFailed {
            _ = writeAll(Data("0\r\n\r\n".utf8))
        }
        done.signal()
    }

    private func sendError(status: Int, message: String) {
        guard !sentHeaders else { return }
        let object: [String: Any] = ["error": ["message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let head = "HTTP/1.1 \(status) Router Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = writeAll(Data(head.utf8))
        _ = writeAll(body)
        sentHeaders = true
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < data.count {
                let result = Darwin.write(clientFD, base.advanced(by: written), data.count - written)
                if result > 0 {
                    written += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

struct LocalModelRouter {
    private let stateURL: URL

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? codexHomeDirectory()
            .appendingPathComponent("model-manager/router-state.json")
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ManagerError.message("无法创建本地模型路由器") }

        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = modelRouterPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(routerHost))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 32) == 0 else {
            Darwin.close(listener)
            throw ManagerError.message("无法监听本地模型路由端口 \(modelRouterPort)")
        }

        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                Darwin.close(listener)
                throw ManagerError.message("本地模型路由器连接失败")
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
            DispatchQueue.global(qos: .userInitiated).async {
                Self.handle(clientFD: client, stateURL: stateURL)
            }
        }
    }

    private static func handle(clientFD: Int32, stateURL: URL) {
        defer { Darwin.close(clientFD) }
        do {
            let request = try readRequest(clientFD)
            let state = try loadState(stateURL)
            guard let secret = state.routerSecret,
                  !secret.isEmpty,
                  request.header("X-Codex-Model-Manager-Token") == secret else {
                sendSimple(clientFD, status: 403, message: "Invalid router token")
                return
            }

            let model = modelID(from: request.body)
            let customProvider = state.providers.first {
                $0.canActivate && $0.model.id == model
            }
            if let customProvider, customProvider.isAntigravityBridge {
                handleAntigravity(clientFD: clientFD, request: request, provider: customProvider)
                return
            }
            let upstream = try upstreamURL(for: request, customProvider: customProvider)
            var forwarded = URLRequest(url: upstream)
            forwarded.httpMethod = request.method
            let body = sanitizedBody(request.body, for: customProvider)
            forwarded.httpBody = body.isEmpty ? nil : body
            forwarded.timeoutInterval = 3600

            for (name, value) in request.headers {
                let lower = name.lowercased()
                if ["host", "content-length", "transfer-encoding", "connection", "proxy-connection", "accept-encoding", "x-codex-model-manager-token"].contains(lower) {
                    continue
                }
                if customProvider != nil,
                   ["authorization", "chatgpt-account-id", "openai-organization", "openai-project", "cookie"].contains(lower) {
                    continue
                }
                forwarded.addValue(value, forHTTPHeaderField: name)
            }
            forwarded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let customProvider {
                guard let key = KeychainStore.read(account: customProvider.id), !key.isEmpty else {
                    sendSimple(clientFD, status: 503, message: "Custom provider key is unavailable")
                    return
                }
                forwarded.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let delegate = StreamingProxyDelegate(clientFD: clientFD)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3600
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            session.dataTask(with: forwarded).resume()
            delegate.wait()
            session.finishTasksAndInvalidate()
        } catch {
            sendSimple(clientFD, status: 400, message: error.localizedDescription)
        }
    }

    private static func loadState(_ url: URL) throws -> PersistedState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedState.self, from: Data(contentsOf: url))
    }

    private static func handleAntigravity(
        clientFD: Int32,
        request: RouterRequest,
        provider: ModelProvider
    ) {
        guard request.method.uppercased() == "POST",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendSimple(clientFD, status: 400, message: "Invalid Responses request")
            return
        }
        let prompt = antigravityPrompt(from: object)
        guard !prompt.isEmpty else {
            sendSimple(clientFD, status: 400, message: "Antigravity bridge received an empty prompt")
            return
        }

        let result = AntigravityCLI.bridge(model: provider.model.id, prompt: prompt)
        let jsonOutput = result.output.components(separatedBy: .newlines).reversed().first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        } ?? result.output
        guard result.status == 0,
              let data = jsonOutput.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AntigravityEnvelope.self, from: data),
              envelope.status?.uppercased() == "SUCCESS" else {
            sendSimple(
                clientFD,
                status: 502,
                message: "Antigravity request failed: \(result.output.lastLines(4))"
            )
            return
        }

        let response = responsesObject(
            model: provider.model.id,
            text: envelope.response,
            usage: envelope.usage,
            previousResponseID: object["previous_response_id"] as? String
        )
        if object["stream"] as? Bool == true {
            sendResponsesStream(clientFD, response: response, text: envelope.response)
        } else if let body = try? JSONSerialization.data(withJSONObject: response) {
            sendHTTP(clientFD, status: 200, contentType: "application/json", body: body)
        } else {
            sendSimple(clientFD, status: 500, message: "Unable to encode Antigravity response")
        }
    }

    private static func antigravityPrompt(from object: [String: Any]) -> String {
        var sections = [
            "You are the language model behind a Codex client. Do not call Antigravity's own tools. "
            + "Answer the supplied conversation directly as plain text. If the request requires a tool action, "
            + "describe the action or code precisely; this bridge currently returns text only."
        ]
        if let instructions = object["instructions"] as? String, !instructions.isEmpty {
            sections.append("Instructions:\n\(instructions)")
        }
        if let input = object["input"] as? String, !input.isEmpty {
            sections.append("User:\n\(input)")
        } else if let items = object["input"] as? [[String: Any]] {
            for item in items {
                let type = item["type"] as? String ?? ""
                if type == "function_call_output" {
                    let output = textValue(item["output"])
                    if !output.isEmpty { sections.append("Tool result:\n\(output)") }
                    continue
                }
                let role = (item["role"] as? String ?? "context").capitalized
                let content = textValue(item["content"])
                if !content.isEmpty { sections.append("\(role):\n\(content)") }
            }
        }
        return sections.joined(separator: "\n\n").prefix(240_000).description
    }

    private static func textValue(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let values = value as? [Any] else { return "" }
        return values.compactMap { entry -> String? in
            if let text = entry as? String { return text }
            guard let object = entry as? [String: Any] else { return nil }
            if let text = object["text"] as? String { return text }
            if let output = object["output"] as? String { return output }
            return nil
        }.joined(separator: "\n")
    }

    private static func responsesObject(
        model: String,
        text: String,
        usage: AntigravityEnvelope.Usage?,
        previousResponseID: String?
    ) -> [String: Any] {
        let responseID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let inputTokens = usage?.input_tokens ?? 0
        let outputTokens = usage?.output_tokens ?? 0
        return [
            "id": responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "instructions": NSNull(),
            "model": model,
            "output": [[
                "id": messageID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": text,
                    "annotations": []
                ]]
            ]],
            "parallel_tool_calls": false,
            "previous_response_id": previousResponseID ?? NSNull(),
            "store": false,
            "usage": [
                "input_tokens": inputTokens,
                "input_tokens_details": ["cached_tokens": 0],
                "output_tokens": outputTokens,
                "output_tokens_details": ["reasoning_tokens": 0],
                "total_tokens": usage?.total_tokens ?? (inputTokens + outputTokens)
            ]
        ]
    }

    private static func sendResponsesStream(
        _ fd: Int32,
        response: [String: Any],
        text: String
    ) {
        guard let output = response["output"] as? [[String: Any]],
              let item = output.first,
              let itemID = item["id"] as? String else {
            sendSimple(fd, status: 500, message: "Unable to stream Antigravity response")
            return
        }
        var created = response
        created["status"] = "in_progress"
        created["output"] = []
        var events: [[String: Any]] = [
            ["type": "response.created", "response": created],
            ["type": "response.output_item.added", "output_index": 0, "item": [
                "id": itemID, "type": "message", "status": "in_progress", "role": "assistant", "content": []
            ]],
            ["type": "response.content_part.added", "item_id": itemID, "output_index": 0,
             "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]],
            ["type": "response.output_text.delta", "item_id": itemID, "output_index": 0,
             "content_index": 0, "delta": text],
            ["type": "response.output_text.done", "item_id": itemID, "output_index": 0,
             "content_index": 0, "text": text],
            ["type": "response.content_part.done", "item_id": itemID, "output_index": 0,
             "content_index": 0, "part": ["type": "output_text", "text": text, "annotations": []]],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": response]
        ]
        for index in events.indices { events[index]["sequence_number"] = index }
        var body = Data()
        for event in events {
            guard let eventType = event["type"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: event) else { continue }
            body.append(Data("event: \(eventType)\ndata: ".utf8))
            body.append(data)
            body.append(Data("\n\n".utf8))
        }
        sendHTTP(fd, status: 200, contentType: "text/event-stream", body: body)
    }

    private static func sendHTTP(
        _ fd: Int32,
        status: Int,
        contentType: String,
        body: Data
    ) {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + body
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < response.count {
                let count = Darwin.write(fd, base.advanced(by: written), response.count - written)
                if count > 0 { written += count }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    private static func modelID(from body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["model"] as? String
    }

    /// Gemini 3 requires a provider-specific `tool_config` opt-in when a request
    /// combines built-in server tools with function declarations. OpenAI
    /// Responses clients do not expose that Gemini-only field, and relays often
    /// drop it. Keep function tools usable by removing only built-in entries for
    /// Gemini-like providers when both kinds are present.
    static func sanitizedBody(_ body: Data, for provider: ModelProvider?) -> Data {
        guard let provider, provider.isGeminiLike,
              !body.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var tools = object["tools"] as? [[String: Any]] else {
            return body
        }

        let builtInTypes: Set<String> = [
            "web_search_preview", "web_search", "file_search", "code_interpreter",
            "computer_use_preview", "computer_use", "image_generation"
        ]
        let hasFunction = tools.contains { ($0["type"] as? String) == "function" }
        let hasBuiltIn = tools.contains {
            guard let type = $0["type"] as? String else { return false }
            return builtInTypes.contains(type)
        }
        guard hasFunction && hasBuiltIn else { return body }

        tools.removeAll {
            guard let type = $0["type"] as? String else { return false }
            return builtInTypes.contains(type)
        }
        object["tools"] = tools
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    private static func upstreamURL(for request: RouterRequest, customProvider: ModelProvider?) throws -> URL {
        let localPrefix = "/v1"
        let path = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(path[0])
        let suffix = rawPath.hasPrefix(localPrefix) ? String(rawPath.dropFirst(localPrefix.count)) : rawPath
        let query = path.count > 1 ? "?\(path[1])" : ""
        let base: String
        if let customProvider {
            base = customProvider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if request.header("ChatGPT-Account-ID") != nil {
            base = "https://chatgpt.com/backend-api/codex"
        } else {
            base = "https://api.openai.com/v1"
        }
        guard let url = URL(string: base + "/" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + query) else {
            throw ManagerError.message("无法生成上游 API 地址")
        }
        return url
    }

    private static func readRequest(_ fd: Int32) throws -> RouterRequest {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var headerRange: Range<Data.Index>?
        while headerRange == nil && data.count < 1_048_576 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw ManagerError.message("请求头不完整") }
            data.append(buffer, count: count)
            headerRange = data.range(of: delimiter)
        }
        guard let range = headerRange,
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw ManagerError.message("请求头无效")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        guard first.count >= 2 else { throw ManagerError.message("请求行无效") }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let contentLength = headers.first {
            $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.1) } ?? 0
        var body = Data(data[range.upperBound...])
        while body.count < contentLength {
            let count = Darwin.read(fd, &buffer, min(buffer.count, contentLength - body.count))
            guard count > 0 else { throw ManagerError.message("请求正文不完整") }
            body.append(buffer, count: count)
        }
        if body.count > contentLength { body = body.prefix(contentLength) }
        return RouterRequest(method: first[0], path: first[1], headers: headers, body: body)
    }

    private static func sendSimple(_ fd: Int32, status: Int, message: String) {
        let body = Data("{\"error\":{\"message\":\"\(jsonEscape(message))\"}}".utf8)
        let response = Data("HTTP/1.1 \(status) Router Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        response.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, response.count) }
        }
    }

    private static func jsonEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
