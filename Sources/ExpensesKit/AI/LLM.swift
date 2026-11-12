import Foundation

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var argumentsJSON: String
    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct ChatMessage: Sendable, Hashable {
    public var role: String          // system | user | assistant | tool
    public var content: String
    public var imagesBase64: [String] = []
    public var toolCalls: [ToolCall] = []
    public var toolName: String? = nil
    public init(role: String, content: String, imagesBase64: [String] = [], toolCalls: [ToolCall] = [], toolName: String? = nil) {
        self.role = role; self.content = content; self.imagesBase64 = imagesBase64
        self.toolCalls = toolCalls; self.toolName = toolName
    }
    public static func system(_ s: String) -> ChatMessage { .init(role: "system", content: s) }
    public static func user(_ s: String, images: [String] = []) -> ChatMessage { .init(role: "user", content: s, imagesBase64: images) }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parametersJSON: String    // JSON Schema object
    public var mutates: Bool             // write tools need a confirm card
}

public struct ChatReply: Sendable, Hashable {
    public var content: String
    public var toolCalls: [ToolCall]
}

/// Abstraction over the model so tests can inject a deterministic fake.
public protocol LLM: Sendable {
    func chat(_ messages: [ChatMessage], tools: [ToolSpec], temperature: Double) async throws -> ChatReply
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum LLMError: Error, CustomStringConvertible {
    case unreachable(String)
    case http(Int, String)
    case badResponse(String)
    public var description: String {
        switch self {
        case .unreachable(let m): return "AI offline (Ollama not reachable): \(m)"
        case .http(let c, let b): return "AI error HTTP \(c): \(b.prefix(200))"
        case .badResponse(let m): return "AI returned an unexpected response: \(m)"
        }
    }
}

/// Local Ollama, non-streaming /api/chat and /api/embed.
public final class OllamaLLM: LLM, @unchecked Sendable {
    public let baseURL: URL
    public let chatModel: String
    public let embedModel: String
    private let session: URLSession

    public init(baseURL: String = "http://127.0.0.1:11434", chatModel: String = "qwen3.5:9b",
                embedModel: String = "qwen3-embedding:0.6b", timeout: TimeInterval = 300) {
        self.baseURL = URL(string: baseURL)!
        self.chatModel = chatModel
        self.embedModel = embedModel
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: cfg)
    }

    public func isReachable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/version"))
        req.timeoutInterval = 3
        return ((try? await session.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    public func chat(_ messages: [ChatMessage], tools: [ToolSpec], temperature: Double) async throws -> ChatReply {
        let msgs: [[String: Any]] = messages.map { m in
            var o: [String: Any] = ["role": m.role, "content": m.content]
            if !m.imagesBase64.isEmpty { o["images"] = m.imagesBase64 }
            if !m.toolCalls.isEmpty {
                o["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                    let args = (try? JSONSerialization.jsonObject(with: Data(tc.argumentsJSON.utf8))) ?? [String: Any]()
                    return ["function": ["name": tc.name, "arguments": args]]
                }
            }
            if let n = m.toolName { o["tool_name"] = n }
            return o
        }
        var body: [String: Any] = [
            "model": chatModel, "messages": msgs, "stream": false, "think": false,
            "options": ["temperature": temperature, "num_predict": 2048],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                let params = (try? JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))) ?? [:]
                return ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": params]]
            }
        }
        let obj = try await post("/api/chat", body)
        guard let msg = obj["message"] as? [String: Any] else { throw LLMError.badResponse("no message") }
        var calls: [ToolCall] = []
        for c in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let fn = c["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
            var args = "{}"
            if let d = fn["arguments"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d) {
                args = String(data: data, encoding: .utf8) ?? "{}"
            } else if let s = fn["arguments"] as? String { args = s }
            calls.append(ToolCall(id: (c["id"] as? String) ?? UUID().uuidString, name: name, argumentsJSON: args))
        }
        return ChatReply(content: (msg["content"] as? String) ?? "", toolCalls: calls)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let obj = try await post("/api/embed", ["model": embedModel, "input": texts])
        guard let e = obj["embeddings"] as? [[Double]] else { throw LLMError.badResponse("no embeddings") }
        return e.map { $0.map(Float.init) }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw LLMError.unreachable(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse("not JSON") }
        return obj
    }
}

/// Pulls the first {...} object out of a model reply (handles ```json fences and chatter).
public func extractJSONObject(_ raw: String) -> String? {
    guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
    return String(raw[start...end])
}
