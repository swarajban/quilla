import AVFoundation
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        backfillNotes(in: root, entries: entries)
        drainIfIdle()
    }

    /// Notes mirroring only ever runs inside `transcribe()`, which skips
    /// sessions that already have a transcript — so a one-off `syncNotes`
    /// failure (volume offline, crash mid-copy) would otherwise lose the vault
    /// copy forever. On relaunch, re-mirror any completed session whose vault
    /// summary is missing. Sessions without a summary (disabled/failed) have
    /// nothing to mirror. Cheap because the copy is idempotent.
    private func backfillNotes(in root: URL, entries: [URL]) {
        guard Config.notesDir() != nil, let notesRoot = Config.notesDir() else { return }
        let fm = FileManager.default
        for dir in entries {
            let session = dir.lastPathComponent
            guard fm.fileExists(atPath: dir.appendingPathComponent("summary.md").path) else {
                continue
            }
            let summaryMirror = notesRoot.appendingPathComponent("quill-summary-\(session).md")
            guard !fm.fileExists(atPath: summaryMirror.path) else { continue }
            syncNotes(from: dir)
        }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        // Resume/retry safety: a crash between writing transcript.json and the
        // caller finishing means re-processing a done session is a no-op.
        if FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path
        ) {
            log(dir, "transcript already exists — skipping")
            return
        }

        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        // Locked segments/gaps captured by the streaming STT pass, keyed by
        // track file. Tracks without streaming data fall back to batch.
        let streamed = StreamingIndex.read(from: dir)

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            if let entry = streamed?[track.file],
               !entry.words.isEmpty || !entry.gaps.isEmpty {
                log(dir, "merging streamed \(track.file) "
                    + "(\(entry.words.count) words, \(entry.gaps.count) gaps)")
                var trackSegments = Segmentizer.segments(from: entry.words)
                for gap in entry.gaps.sorted(by: { $0.from < $1.from }) {
                    do {
                        trackSegments += try await transcribeRange(
                            file: audio, from: gap.from, to: gap.to, engine: engine)
                    } catch {
                        log(dir, "gap fill \(track.file) \(gap.from)-\(gap.to)s: \(error)")
                    }
                }
                segments = trackSegments.sorted { $0.start < $1.start }
            } else {
                log(dir, "transcribing \(track.file) (\(engine.name))")
                do {
                    segments = try await engine.transcribe(audio)
                } catch {
                    log(dir, "skipping \(track.file): \(error)")
                    continue
                }
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
        await summarize(transcript: transcript, to: dir)
        syncNotes(from: dir)
    }

    /// Batch-transcribe one time range of a track file (a streaming reconnect
    /// gap). Decodes the span from the CAF to a temp PCM file, runs the
    /// regular engine over it, and offsets the results to track time.
    private func transcribeRange(
        file: URL, from start: Double, to end: Double, engine: TranscriptionEngine
    ) async throws -> [TranscriptSegment] {
        let source = try AVAudioFile(forReading: file)
        let rate = source.processingFormat.sampleRate
        source.framePosition = Int64(start * rate)
        let frames = AVAudioFrameCount(max(0, (end - start) * rate))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: source.processingFormat, frameCapacity: frames)
        else { return [] }
        try source.read(into: buffer, frameCount: frames)
        guard buffer.frameLength > 0 else { return [] }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-gap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = try AVAudioFile(forWriting: tmp, settings: source.processingFormat.settings)
        try out.write(from: buffer)

        return try await engine.transcribe(tmp).map {
            TranscriptSegment(start: $0.start + start, end: $0.end + start, text: $0.text)
        }
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let engine: TranscriptionEngine
        switch Config.transcriptionEngine() {
        case "xai":
            engine = XAISttEngine()
        case "parakeet":
            if !Config.transcriptionKeyTerms().isEmpty {
                FileHandle.standardError.write(Data(
                    "note: transcription.key_terms ignored — Parakeet cannot accept vocabulary hints\n".utf8
                ))
            }
            engine = ParakeetEngine()
        default:
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(Config.transcriptionEngine())\" — using parakeet\n".utf8
            ))
            engine = ParakeetEngine()
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Optional, best-effort: ask the configured LLM to summarize the just-
    /// written transcript. Failures are logged, never propagated — the
    /// transcript is the artifact; the summary is a convenience on top. Start
    /// and finish are logged so a slow/billed request time is visible in
    /// transcribe.log.
    private func summarize(transcript: Transcript, to dir: URL) async {
        guard Config.summaryEnabled() else { return }
        log(dir, "summarizing with \(Config.summaryProvider())/\(Config.summaryModelResolved())")
        let start = Date()
        do {
            let output = try await Summarizer.summarize(transcript.summaryText)
            try SummaryDocument.write(output, to: dir)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log(dir, "summary done in \(ms)ms (\(output.provider)/\(output.model))")
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log(dir, "summary failed after \(ms)ms: \(error)")
        }
    }

    /// Copy the summary into the notes vault (config `notes_dir`), flat, with
    /// the session name baked into the filename so time-based search works:
    /// `<vault>/quill-summary-2026-08-06-1430-test.md`. Transcripts, audio,
    /// and JSON stay in the recordings root — the vault gets only the
    /// distilled note. Best-effort; a failure is logged and never blocks the
    /// session.
    private func syncNotes(from dir: URL) {
        guard let notesRoot = Config.notesDir() else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: notesRoot, withIntermediateDirectories: true)
        } catch {
            log(dir, "notes dir create failed: \(error)")
            return
        }
        let session = dir.lastPathComponent
        let srcURL = dir.appendingPathComponent("summary.md")
        guard fm.fileExists(atPath: srcURL.path) else { return }
        let dst = notesRoot.appendingPathComponent("quill-summary-\(session).md")
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }
        do {
            try fm.copyItem(at: srcURL, to: dst)
        } catch {
            log(dir, "notes summary.md copy failed: \(error)")
        }
        // Legacy cleanup: earlier builds mirrored the transcript too.
        try? fm.removeItem(
            at: notesRoot.appendingPathComponent("quill-transcript-\(session).md")
        )
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// Index of transcript.streaming.jsonl: per track file, the locked words
/// (track-relative seconds) and the reconnect gaps that were never streamed.
private struct StreamingIndex {
    struct Entry {
        var words: [TimedWord] = []
        var gaps: [(from: Double, to: Double)] = []
    }

    static func read(from dir: URL) -> [String: Entry]? {
        let url = dir.appendingPathComponent("transcript.streaming.jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var index: [String: Entry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let track = obj["track"] as? String
            else { continue }
            var entry = index[track] ?? Entry()
            if let gap = obj["gap"] as? [Double], gap.count == 2 {
                entry.gaps.append((gap[0], gap[1]))
            } else if let base = obj["base"] as? Double,
                      let words = obj["words"] as? [[String: Any]] {
                for w in words {
                    guard let text = w["text"] as? String,
                          let start = w["start"] as? Double,
                          let end = w["end"] as? Double
                    else { continue }
                    entry.words.append(TimedWord(
                        text: text, start: base + start, end: base + end))
                }
            }
            index[track] = entry
        }
        return index.isEmpty ? nil : index
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: Any]
        else { throw MetaError.unreadable(url) }

        // Values are either a single file/offset (one recording leg) or an
        // array (resumed sessions append one entry per leg). Sessions from
        // before offsets were captured default to 0 — tracks start within
        // tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Any] ?? [:]
        func list<T>(_ value: Any?) -> [T] {
            if let array = value as? [T] { return array }
            if let single = value as? T { return [single] }
            return []
        }
        var tracks: [Track] = []
        for (speaker, key) in [("me", "mic"), ("them", "system")] {
            let fileList: [String] = list(files[key])
            let offsetList: [Int] = list(offsets[key])
            for (i, file) in fileList.enumerated() {
                tracks.append(Track(
                    file: file,
                    speaker: speaker,
                    offsetMs: i < offsetList.count ? offsetList[i] : 0
                ))
            }
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain speaker-tagged text for the summarizer prompt — same content as
    /// the markdown render without the markup, which would just cost tokens.
    var summaryText: String {
        segments.map { "[\(Self.clock($0.start_ms))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
