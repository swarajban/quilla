import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession: @unchecked Sendable {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    /// Live WebSocket STT while recording (xAI engine only) — feeds locked
    /// segments to transcript.streaming.jsonl so stop-time transcription is
    /// a merge, not a full batch. Nil when streaming is off or Parakeet.
    private(set) var streaming: StreamingSession?

    // Resume support: a resumed session writes new track files into the
    // existing folder and appends to meta.json rather than replacing it.
    private let resumeOriginStart: Date?
    private var micFile = "mic.caf"
    private var systemFile = "system.caf"

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        // 24-hour clock, zero-padded (`HH`): keeps the timestamp part
        // strictly lexicographic = chronological, so folder sorting and the
        // name-based order of resume/recent lists stay correct.
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (e.g. `2026-08-06-1430` or
    /// `2026-08-06-1430-team-sync` when named, suffixed on collision) without
    /// starting capture yet.
    init(root: URL, name: String? = nil) throws {
        let base = Self.folderBase(for: name, at: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        resumeOriginStart = nil
    }

    /// Resume a stopped meeting in place: new audio lands in the SAME folder
    /// as `mic.r1.caf`/`system.r1.caf` (suffix bumps per resume), meta.json
    /// gains track entries on stop, and the transcript/summary artifacts are
    /// cleared so the post-stop pipeline reprocesses the whole meeting.
    init(resumeInto existing: URL) throws {
        dir = existing
        // The original session clock anchors the resumed tracks' offsets.
        var origin: Date?
        if let data = try? Data(contentsOf: existing.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let started = meta["started"] as? String {
            origin = ISO8601DateFormatter().date(from: started)
        }
        resumeOriginStart = origin

        var n = 1
        while FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("mic.r\(n).caf").path
        ) { n += 1 }
        micFile = "mic.r\(n).caf"
        systemFile = "system.r\(n).caf"

        // Force the pipeline to redo the merged artifacts.
        for artifact in ["transcript.json", "transcript.md", "summary.md"] {
            try? FileManager.default.removeItem(at: existing.appendingPathComponent(artifact))
        }
    }

    // MARK: - Folder naming

    /// `<yyyy-MM-dd-HHmm>` plus an optional slugified name: the
    /// timestamp-first order keeps folders chronologically sortable by name;
    /// the name makes recurring meetings findable on disk and in the vault.
    static func folderBase(for name: String?, at date: Date) -> String {
        let ts = folderFormat.string(from: date)
        guard let name, !name.isEmpty else { return ts }
        let slug = slugify(name)
        return slug.isEmpty ? ts : "\(ts)-\(slug)"
    }

    /// Filesystem-safe token for arbitrary input: precomposed, lowercased,
    /// runs of non-alphanumerics collapse to a single dash, capped so a long
    /// pasted subject can't overflow the folder or vault file name. Unicode
    /// letters survive so non-English meeting names still read naturally.
    static func slugify(_ name: String) -> String {
        let precomposed = name.precomposedStringWithCanonicalMapping.lowercased()
        var out = ""
        var pendingDash = false
        for ch in precomposed {
            if ch.isLetter || ch.isNumber {
                if pendingDash { out.append("-"); pendingDash = false }
                out.append(ch)
            } else {
                pendingDash = !out.isEmpty && !out.hasSuffix("-")
            }
        }
        if out.count > 80 {
            out = String(out.prefix(80))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    private static let nameSlugRegex = try! NSRegularExpression(
        // The optional `[ap]` keeps names parseable in folders created by
        // the previous 12-hour naming scheme (`2026-08-06-0230p-team-sync`).
        pattern: "^\\d{4}-\\d{2}-\\d{2}-\\d{3,4}[ap]?-(.+)$"
    )

    /// The display name embedded in a named session folder
    /// (`2026-08-06-1430-team-sync` → `team sync`), or nil if the folder has
    /// no name. Used to surface recently used names at the next recording.
    static func name(from folder: String) -> String? {
        let range = NSRange(folder.startIndex..<folder.endIndex, in: folder)
        guard let match = Self.nameSlugRegex.firstMatch(in: folder, range: range),
              let slugRange = Range(match.range(at: 1), in: folder)
        else { return nil }
        let slug = String(folder[slugRange])
        // A pure-numeric slug is a collision suffix, not a name
        // (`2026-08-06-1430-2`).
        if slug.allSatisfy(\.isNumber) { return nil }
        let display = slug.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return display.isEmpty ? nil : display
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        // Sinks attach before start so the recorders set up their converter
        // chains; the streaming client itself connects lazily on first audio
        // (the track's sample rate doesn't exist before engine start).
        if Config.transcriptionStreaming(), Config.transcriptionEngine() == "xai" {
            let stream = StreamingSession(dir: dir)
            mic.pcm16Sink = stream.attach(track: micFile) { [weak mic] in
                mic?.streamSampleRate ?? 0
            }
            system.pcm16Sink = stream.attach(track: systemFile) { [weak system] in
                system?.streamSampleRate ?? 0
            }
            streaming = stream
        }
        try system.start(writingTo: dir.appendingPathComponent(systemFile))
        do {
            try mic.start(writingTo: dir.appendingPathComponent(micFile))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Drain and close the streaming connections. Must complete before the
    /// session folder is enqueued for transcription.
    func finishStreaming() async {
        await streaming?.finish()
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any]
        if let origin = resumeOriginStart,
           let existing = try? JSONSerialization.jsonObject(
               with: Data(contentsOf: dir.appendingPathComponent("meta.json"))
           ) as? [String: Any] {
            // Merge into the existing meta: files/offsets become arrays with
            // one entry per recording leg. Resumed offsets anchor to the
            // original session start (within tens of ms of the original
            // tracks' clock — irrelevant at transcript granularity).
            func appended(_ key: String, _ dict: [String: Any], _ new: Any) -> [Any] {
                switch dict[key] {
                case let array as [Any]: return array + [new]
                case let single?: return [single, new]
                case nil: return [new]
                }
            }
            var files = existing["files"] as? [String: Any] ?? [:]
            var offsets = existing["start_offset_ms"] as? [String: Any] ?? [:]
            files["mic"] = appended("mic", files, micFile)
            files["system"] = appended("system", files, systemFile)
            offsets["mic"] = appended(
                "mic", offsets, Int(micStart.timeIntervalSince(origin) * 1000))
            offsets["system"] = appended(
                "system", offsets, Int(systemStart.timeIntervalSince(origin) * 1000))
            meta = [
                "started": iso.string(from: origin),
                "ended": iso.string(from: ended),
                "duration_seconds": Int(ended.timeIntervalSince(origin)),
                "files": files,
                "start_offset_ms": offsets,
            ]
        } else {
            meta = [
                "started": iso.string(from: startedAt),
                "ended": iso.string(from: ended),
                "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
                "files": ["mic": micFile, "system": systemFile],
                "start_offset_ms": [
                    "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                    "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
                ],
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
