import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "xai", "language": "en" },
///       "summary": { "enabled": true, "provider": "xai", "model": "grok-4.5", "prompt": "..." },
///       "api_keys": { "xai": "...", "anthropic": "..." },
///       "notes_dir": "~/Documents/Obsidian/Meetings",
///       "mic_voice_processing": true,
///       "dictation": { "enabled": true, "hotkey": "caps_lock" },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
///
/// API keys resolve as: environment variable first (XAI_API_KEY,
/// ANTHROPIC_API_KEY), then the `api_keys` dict. Keys are read from the
/// config file rather than the environment alone so the LaunchAgent works
/// without hand-editing its plist; keep the file readable only by you
/// (chmod 600 ~/.config/quill/config.json).
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name: "xai" (cloud, default) or "parakeet" (local).
    /// Anything else gets a warning and the parakeet fallback.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "xai"
    }

    /// Language hint for the xAI STT "format" (inverse text normalization)
    /// pass. The model transcribes any language; this only formats numbers and
    /// currency. Parakeet ignores it.
    static func transcriptionLanguage() -> String {
        transcription()?["language"] as? String ?? "en"
    }

    /// Stream audio to xAI's WebSocket STT while recording, so stop-time
    /// transcription merges locked segments instead of batch-uploading whole
    /// tracks. Default on; only used with the xai engine. Reconnect gaps are
    /// batch-filled from the local recordings at stop.
    static func transcriptionStreaming() -> Bool {
        transcription()?["streaming"] as? Bool ?? true
    }

    /// Key terms/concepts (names, jargon, project codewords) passed to the
    /// cloud STT as `keyterm` hints so they are spelled correctly. API limit:
    /// 100 terms of 50 chars each (enforced with a 400; XAISttEngine clamps).
    /// Empty when unset. Parakeet cannot accept hints and ignores this.
    static func transcriptionKeyTerms() -> [String] {
        transcription()?["key_terms"] as? [String] ?? []
    }

    /// Whether transcripts are summarized by an LLM after transcription.
    /// Default on — set false to skip the (optional, billed) API call.
    static func summaryEnabled() -> Bool {
        guard let summary else { return true }
        return summary["enabled"] as? Bool ?? true
    }

    /// Summarization provider: "xai" (default) or "anthropic".
    static func summaryProvider() -> String {
        summary?["provider"] as? String ?? "xai"
    }

    /// Optional per-provider model override. Defaults: grok-4.5 (xai),
    /// claude-sonnet-5 (anthropic).
    static func summaryModel() -> String? {
        summary?["model"] as? String
    }

    private static func summarizeDefaultModel() -> String {
        switch summaryProvider() {
        case "anthropic": return "claude-sonnet-5"
        default: return "grok-4.5"
        }
    }

    /// The model actually used for summarization: configured model or the
    /// provider default.
    static func summaryModelResolved() -> String {
        summaryModel() ?? summarizeDefaultModel()
    }

    /// Optional system-prompt override for the summarizer. The safety clause
    /// (transcript is untrusted data) is always appended — a custom prompt
    /// can't waive it. Unset by default.
    static func summaryPrompt() -> String? {
        guard let prompt = summary?["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return prompt
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    private static var summary: [String: Any]? {
        load()?["summary"] as? [String: Any]
    }

    /// Optional vault folder for meeting summaries. When set, a copy of
    /// every session's summary.md lands in it flat, named
    /// `quill-summary-<session>.md` (session = the timestamp+named folder,
    /// e.g. `2026-08-06-1430-test`), so an Obsidian vault (or plain
    /// Dropbox-style sync) can pick it up while transcripts and audio stay in
    /// the recordings root. Unset by default — notes live with their
    /// recordings.
    static func notesDir() -> URL? {
        guard let dir = load()?["notes_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// API key for a provider ("xai", "anthropic"). Environment variable
    /// (XAI_API_KEY / ANTHROPIC_API_KEY) wins over the config file, so
    /// terminal runs can override what the LaunchAgent uses.
    static func apiKey(_ name: String) -> String? {
        let envName = name.uppercased() + "_API_KEY"
        if let env = ProcessInfo.processInfo.environment[envName], !env.isEmpty {
            return env
        }
        guard let keys = load()?["api_keys"] as? [String: Any],
              let value = keys[name.lowercased()] as? String, !value.isEmpty
        else { return nil }
        return value
    }

    /// Push-to-talk dictation: the global hotkey toggles mic capture, and on
    /// stop the transcript is pasted at the cursor. Default off. Uses the
    /// configured transcription engine. Requires Input Monitoring (global
    /// hotkey) and Accessibility (consuming the key + synthetic ⌘V paste).
    static func dictationEnabled() -> Bool {
        dictation()?["enabled"] as? Bool ?? false
    }

    /// Dictation hotkey name. Only "caps_lock" is supported — caps lock is
    /// consumed while quill runs, so it never toggles case.
    static func dictationHotkey() -> String {
        dictation()?["hotkey"] as? String ?? "caps_lock"
    }

    private static func dictation() -> [String: Any]? {
        load()?["dictation"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
