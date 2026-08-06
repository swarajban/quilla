import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        // 12-hour clock, zero-padded hour (`hh`): keeps the timestamp part
        // strictly lexicographic = chronological, so folder sorting and the
        // name-based order of resume/recent lists stay correct. The `a`/`p`
        // suffix is appended in folderBase (DateFormatter's `a` renders AM/PM).
        f.dateFormat = "yyyy-MM-dd-hhmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (e.g. `2026-08-06-230p` or
    /// `2026-08-06-230p-team-sync` when named, suffixed on collision) without
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
    }

    // MARK: - Folder naming

    /// `<yyyy-MM-dd-hmm><a|p>` plus an optional slugified name: the
    /// timestamp-first order keeps folders chronologically sortable by date;
    /// the name makes recurring meetings findable on disk and in the vault.
    static func folderBase(for name: String?, at date: Date) -> String {
        var ts = folderFormat.string(from: date)
        let hour = Calendar.current.component(.hour, from: date)
        ts += hour >= 12 ? "p" : "a"
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
        pattern: "^\\d{4}-\\d{2}-\\d{2}-\\d{1,4}[ap]-(.+)$"
    )

    /// The display name embedded in a named session folder
    /// (`2026-08-06-230p-team-sync` → `team sync`), or nil if the folder has
    /// no name. Used to surface recently used names at the next recording.
    static func name(from folder: String) -> String? {
        let range = NSRange(folder.startIndex..<folder.endIndex, in: folder)
        guard let match = Self.nameSlugRegex.firstMatch(in: folder, range: range),
              let slugRange = Range(match.range(at: 1), in: folder)
        else { return nil }
        let slug = String(folder[slugRange])
        // A pure-numeric slug is a collision suffix, not a name
        // (`2026-08-06-230p-2`).
        if slug.allSatisfy(\.isNumber) { return nil }
        let display = slug.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return display.isEmpty ? nil : display
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
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

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
