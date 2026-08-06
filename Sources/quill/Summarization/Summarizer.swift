import Foundation

/// Post-recording LLM summarization. The transcript's speaker-tagged text goes
/// to a chat model — xAI by default (grok-4.5), Anthropic as the alternative
/// (claude-sonnet-5) — and the reply lands in the session folder as
/// summary.md plus a machine-readable summary.json. Pure URLSession, no new
/// dependencies; the only failure that matters is a missing key, because
/// nothing is uploaded on success beyond the transcript text.
enum Summarizer {
    struct Output: Sendable {
        let text: String
        let provider: String
        let model: String
    }

    enum SummaryError: Error, CustomStringConvertible {
        case missingKey(String)
        case unsupportedProvider(String)
        case requestFailed(Int, String)
        case emptyResponse

        var description: String {
            switch self {
            case .missingKey(let provider):
                return "no API key for \(provider) — add \"api_keys\": {\"\(provider)\": \"...\"} to ~/.config/quill/config.json or export \(provider.uppercased())_API_KEY"
            case .unsupportedProvider(let p): return "unknown summary provider \"\(p)\""
            case .requestFailed(let s, let body):
                return "summary request failed (HTTP \(s)): \(body)"
            case .emptyResponse: return "summary provider returned no text"
            }
        }
    }

    /// Summarize a transcript with the configured provider. Pure — the caller
    /// writes the result to disk.
    static func summarize(_ transcriptText: String) async throws -> Output {
        let providerName = Config.summaryProvider()
        let model = Config.summaryModelResolved()
        guard let key = Config.apiKey(providerName) else {
            throw SummaryError.missingKey(providerName)
        }

        let provider: TextCompleting
        switch providerName {
        case "xai":
            provider = XAICompleter(model: model, apiKey: key)
        case "anthropic":
            provider = AnthropicCompleter(model: model, apiKey: key)
        default:
            throw SummaryError.unsupportedProvider(providerName)
        }

        let text = try await provider.complete(
            system: Self.systemPrompt,
            user: transcriptText
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryError.emptyResponse }
        return Output(text: trimmed, provider: providerName, model: model)
    }

    static let systemPrompt = """
    You are a precise meeting summarization assistant. Given a meeting \
    transcript with speaker tags (me = the person running quill, them = the \
    other party), produce a concise but complete Markdown summary. Use these \
    sections when they have content — omit empty ones:
    - ## Summary (a tight paragraph capturing what the meeting was about and \
    the outcome)
    - ## Key topics (bulleted)
    - ## Decisions (bulleted, concrete)
    - ## Action items (bulleted: owner and what)
    - ## Open questions (bulleted)
    Preserve concrete details: names, numbers, dates, and commitments. Never \
    invent facts not in the transcript.
    """
}

/// A chat-model client. Both implementations are plain structs carrying
/// model + key, so they're Sendable and stateless.
protocol TextCompleting: Sendable {
    func complete(system: String, user: String) async throws -> String
}

// MARK: - xAI (OpenAI-compatible chat completions)

struct XAICompleter: TextCompleting {
    let model: String
    let apiKey: String

    func complete(system: String, user: String) async throws -> String {
        let url = URL(string: "https://api.x.ai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String,
            !text.isEmpty
        else { throw Summarizer.SummaryError.emptyResponse }
        return text
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await HTTPClient.session().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Summarizer.SummaryError.requestFailed(-1, "no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Summarizer.SummaryError.requestFailed(http.statusCode, errorBody(data))
        }
        return data
    }
}

// MARK: - Anthropic (Messages API)

struct AnthropicCompleter: TextCompleting {
    let model: String
    let apiKey: String

    func complete(system: String, user: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            !text.isEmpty
        else { throw Summarizer.SummaryError.emptyResponse }
        return text
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await HTTPClient.session().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Summarizer.SummaryError.requestFailed(-1, "no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Summarizer.SummaryError.requestFailed(http.statusCode, errorBody(data))
        }
        return data
    }
}

/// Best-effort extraction of a provider's error message from a non-2xx body.
private func errorBody(_ data: Data) -> String {
    if
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let message = json["message"] as? String
            ?? (json["error"] as? String)
            ?? (json["error"] as? [String: Any])?["message"] as? String
    {
        return message
    }
    let raw = String(data: data, encoding: .utf8) ?? ""
    return String(raw.prefix(300))
}

/// Canonical summary artifact. summary.json records provenance (provider,
/// model); summary.md is the same text rendered for reading. Both writes are
/// atomic so a partial summary never exists on disk.
struct SummaryDocument: Codable {
    let provider: String
    let model: String
    let created_at: String
    let summary: String

    static func write(_ output: Summarizer.Output, to dir: URL) throws {
        let doc = SummaryDocument(
            provider: output.provider,
            model: output.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            summary: output.text
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc)
            .write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
        try Data(output.text.utf8)
            .write(to: dir.appendingPathComponent("summary.md"), options: .atomic)
    }
}
