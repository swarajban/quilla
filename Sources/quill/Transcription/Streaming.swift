import AVFoundation
import Foundation

/// Live transcription over xAI's WebSocket STT during a meeting, so the
/// transcript is (nearly) done when the meeting ends. One connection per
/// audio track; locked (`is_final`) events are appended to
/// `transcript.streaming.jsonl` in the session folder and merged into the
/// canonical transcript.json on stop. The local recordings stay the source
/// of truth: if streaming fails outright, the coordinator falls back to
/// today's batch path, and reconnect gaps are batch-filled from the files.
///
/// JSONL line shapes (timestamps are seconds, relative to the track's start):
///   {"track":"mic.caf","base":12.3,"words":[{"text":..,"start":..,"end":..}]}
///   {"track":"mic.caf","gap":[120.5, 131.8]}
final class StreamingSession: @unchecked Sendable {

    /// Speech detector threshold on int16 RMS — comfortably above room noise,
    /// well below near-mic speech.
    static let speechRMS: Double = 400

    private let dir: URL
    private let queue = DispatchQueue(label: "com.swarajban.quill.streaming")
    private let lock = NSLock()
    private var clients: [String: StreamingSttClient] = [:]
    private var rateSources: [String: () -> Int] = [:]
    private var jsonl: FileHandle?
    private var lastSpeechAt: [String: Date] = [:]
    private var closed = false
    /// In-memory copy of locked words per track — the live transcript view
    /// reads this; the JSONL stays the durable record.
    private var words: [String: [TimedWord]] = [:]

    init(dir: URL) {
        self.dir = dir
    }

    /// Open the JSONL for appending (created on first use). Called once per
    /// session lifetime; safe to call again on resume.
    private func openLogLocked() -> FileHandle? {
        if let jsonl { return jsonl }
        let url = dir.appendingPathComponent("transcript.streaming.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        jsonl = try? FileHandle(forWritingTo: url)
        _ = try? jsonl?.seekToEnd()
        return jsonl
    }

    private func append(_ object: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let handle = openLogLocked(),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    /// Wire a track into the stream. Returns the sink the recorder feeds with
    /// pcm16le buffers. The sample rate is only known once the recorder's
    /// engine/tap is up, so the client is created lazily on the first buffer.
    func attach(track: String, sampleRate: @escaping @Sendable () -> Int) -> (Data) -> Void {
        lock.lock()
        rateSources[track] = sampleRate
        lastSpeechAt[track] = Date()
        lock.unlock()
        return { [weak self] data in
            self?.queue.async {
                guard let self else { return }
                self.noteEnergy(data, track: track)
                self.client(for: track)?.send(data)
            }
        }
    }

    /// Client lookup/creation — always called on `queue`.
    private func client(for track: String) -> StreamingSttClient? {
        lock.lock()
        if let existing = clients[track] { lock.unlock(); return existing }
        let rate = rateSources[track]?() ?? 0
        lock.unlock()
        // Recorder hasn't produced its format yet — drop this buffer, the
        // next one will connect.
        guard rate > 0 else { return nil }

        let client = StreamingSttClient(sampleRate: rate)
        client.onLocked = { [weak self] base, words in
            guard let self else { return }
            self.lock.lock()
            self.words[track, default: []].append(contentsOf: words)
            self.lock.unlock()
            self.append([
                "track": track,
                "base": base,
                "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
            ])
        }
        client.onGap = { [weak self] from, to in
            self?.append(["track": track, "gap": [from, to]])
        }
        lock.lock()
        clients[track] = client
        lock.unlock()
        client.start()
        return client
    }

    /// RMS over pcm16le samples; updates the track's last-speech clock.
    private func noteEnergy(_ data: Data, track: String) {
        var sumSquares = 0.0
        var count = 0
        data.withUnsafeBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            count = raw.count / 2
            guard count > 0 else { return }
            // Stride to ~8k samples per buffer — plenty for an energy estimate.
            let step = max(1, count / 8192)
            var i = 0
            while i < count {
                let s = Double(samples[i])
                sumSquares += s * s
                i += step
            }
            count = (count + step - 1) / step
        }
        guard count > 0 else { return }
        let rms = (sumSquares / Double(count)).squareRoot()
        if rms > Self.speechRMS {
            lock.lock()
            lastSpeechAt[track] = Date()
            lock.unlock()
        }
    }

    /// Seconds since the most recent speech on ANY track (both-silent
    /// duration) — the idle signal for the menu blink / auto-stop. Nil when
    /// no tracks are attached.
    var idleSeconds: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !lastSpeechAt.isEmpty else { return nil }
        let mostRecent = lastSpeechAt.values.max()!
        return Date().timeIntervalSince(mostRecent)
    }

    /// Live transcript snapshot for the floating panel: locked words run
    /// through the same segmentizer as the final transcript, merged across
    /// tracks by (track-relative) time. Track start offsets (~tens of ms)
    /// are ignored — fine for a preview, exact in the final artifact.
    func liveSegments() -> [(speaker: String, start: Double, text: String)] {
        lock.lock()
        let snapshot = words
        lock.unlock()
        var all: [(speaker: String, start: Double, text: String)] = []
        for (track, trackWords) in snapshot {
            let speaker = track.hasPrefix("mic") ? "me" : "them"
            for segment in Segmentizer.segments(from: trackWords) {
                all.append((speaker, segment.start, segment.text))
            }
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Short menu status: "live", "reconnecting", or "offline".
    var stateDescription: String {
        lock.lock()
        defer { lock.unlock() }
        let states = clients.values.map { $0.state }
        if states.isEmpty { return "off" }
        if states.allSatisfy({ $0 == .live }) { return "live" }
        if states.contains(.live) { return "degraded" }
        return "reconnecting…"
    }

    /// Flush remaining audio, collect final events, close connections.
    /// Must finish before the coordinator reads the JSONL. The log stays open
    /// until the drain completes so final locked events are persisted.
    func finish() async {
        let all = allClients()
        await withTaskGroup(of: Void.self) { group in
            for client in all {
                group.addTask { await client.finish() }
            }
        }
        closeLog()
    }

    private func allClients() -> [StreamingSttClient] {
        lock.lock()
        defer { lock.unlock() }
        return Array(clients.values)
    }

    private func closeLog() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        try? jsonl?.close()
        jsonl = nil
    }
}

/// One track's WebSocket connection to xAI streaming STT, with reconnect and
/// gap tracking. Audio position (`position`) advances with every buffer the
/// recorder hands us — sent or not — so it always matches the track file's
/// timeline. On reconnect we do NOT re-send the gap (that would compress the
/// timeline); the gap is reported and batch-filled from the recording later.
final class StreamingSttClient: @unchecked Sendable {

    enum State { case connecting, live, reconnecting, closed }

    /// (connection-relative base, locked words) — add base + word.start for
    /// track-relative seconds.
    var onLocked: (Double, [TimedWord]) -> Void = { _, _ in }
    /// A span of track time (seconds) that no connection received.
    var onGap: (Double, Double) -> Void = { _, _ in }

    private let sampleRate: Int
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config)
    }()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private(set) var state: State = .connecting
    /// Seconds of track audio handed to us so far (sent or dropped).
    private var position = 0.0
    /// `position` at the moment the current connection opened — add to server
    /// word timestamps for track-relative time.
    private var sessionBase = 0.0
    /// End of the word timeline already persisted from this connection.
    /// Chunk-final and utterance-final events RESTATE earlier words (probed:
    /// identical full word list in both), so only words past this mark are
    /// new — timestamp-based, robust to either cumulative or windowed events.
    private var consumedEnd = 0.0
    private var disconnectAt: Double?
    private var backoff = 1.0
    private var finishing = false
    /// False until the first connection reaches .live — an initial connect
    /// failure gaps from t=0, not from the drop moment.
    private var everLive = false

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    func start() { connect() }

    /// Feed pcm16le audio. Counts toward the position even while disconnected
    /// (the recorder keeps writing the track file either way).
    func send(_ data: Data) {
        lock.lock()
        position += Double(data.count) / (Double(sampleRate) * 2)
        let current = task
        let live = state == .live
        lock.unlock()
        guard live, let current else { return }
        current.send(.data(data)) { [weak self] error in
            if error != nil { self?.connectionDropped() }
        }
    }

    /// Signal end of audio, drain the final transcript, close. No further
    /// reconnects afterwards.
    func finish() async {
        let current = prepareFinish()
        guard let current else { return }
        try? await current.send(.string("{\"type\":\"audio.done\"}"))
        // transcript.done arrives via the receive loop, which then sees the
        // server close; give it a grace window, then force-cancel.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        forceClose(current)
    }

    /// Sync half of finish() (no NSLock across awaits): stop reconnects,
    /// flush any pending disconnect gap, and hand back the live connection.
    private func prepareFinish() -> URLSessionWebSocketTask? {
        lock.lock()
        finishing = true
        pingTimer?.cancel()
        let current = state == .live ? task : nil
        let pendingGap = disconnectAt
        disconnectAt = nil
        let end = position
        let wasClosed = state == .closed
        if current == nil && !wasClosed { state = .closed }
        lock.unlock()
        // A drop that never reconnected by stop time: the tail is a gap.
        if let from = pendingGap, end - from > 0.5 {
            onGap(from, end)
        }
        if wasClosed { return nil }
        return current
    }

    private func forceClose(_ connection: URLSessionWebSocketTask) {
        lock.lock()
        let done = state == .closed
        if !done { state = .closed }
        lock.unlock()
        if !done { connection.cancel(with: .normalClosure, reason: nil) }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        lock.lock()
        if finishing { lock.unlock(); return }
        state = state == .connecting ? .connecting : .reconnecting
        lock.unlock()

        var comps = URLComponents(string: "wss://api.x.ai/v1/stt")!
        var query = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
        ]
        let language = Config.transcriptionLanguage()
        if !language.isEmpty {
            query.append(URLQueryItem(name: "language", value: language))
        }
        for term in Config.transcriptionKeyTerms().prefix(100) {
            query.append(URLQueryItem(name: "keyterm", value: String(term.prefix(50))))
        }
        comps.queryItems = query

        var request = URLRequest(url: comps.url!)
        guard let key = Config.apiKey("xai"), !key.isEmpty else {
            FileHandle.standardError.write(Data("streaming: no xai API key — track stays batch\n".utf8))
            lock.lock()
            state = .closed
            lock.unlock()
            return
        }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let newTask = session.webSocketTask(with: request)
        lock.lock()
        task?.cancel() // zombie predecessor from a ping-detected drop
        task = newTask
        consumedEnd = 0 // new connection restarts its word timeline
        lock.unlock()
        newTask.resume()
        receiveLoop(newTask)
        startPing(newTask)

        lock.lock()
        let wasReconnect = disconnectAt != nil
        if let from = disconnectAt {
            disconnectAt = nil
            sessionBase = position
            let to = position
            lock.unlock()
            if to - from > 0.5 {
                onGap(from, to)
                FileHandle.standardError.write(Data(
                    String(format: "streaming: reconnected — %.1fs gap will be batch-filled\n", to - from).utf8
                ))
            }
        } else {
            sessionBase = position
            lock.unlock()
        }
        if !wasReconnect { backoff = 1.0 }
        lock.lock()
        // A slow initial connect means the audio before it was never sent —
        // record it as a gap (below ~1s is just connect latency, skip).
        if !everLive && position > 1.0 {
            let to = position
            everLive = true
            lock.unlock()
            onGap(0, to)
            lock.lock()
        }
        everLive = true
        state = .live
        lock.unlock()
        FileHandle.standardError.write(Data("streaming: connected (\(sampleRate) Hz)\n".utf8))
    }

    private func receiveLoop(_ connection: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await connection.receive()
                    guard let self else { return }
                    var text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text { self.handleEvent(text) }
                    // Server closes after transcript.done — receive() will
                    // throw next iteration and we exit via the catch.
                } catch {
                    self?.connectionDropped()
                    return
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "transcript.partial":
            // Only locked text is persisted; interim results (off by default)
            // would be for a future live-preview UI.
            guard event["is_final"] as? Bool == true,
                  let rawWords = event["words"] as? [[String: Any]], !rawWords.isEmpty
            else { return }
            let words = rawWords.compactMap { w -> TimedWord? in
                guard let t = w["text"] as? String,
                      let start = w["start"] as? Double,
                      let end = w["end"] as? Double
                else { return nil }
                return TimedWord(text: t, start: start, end: end)
            }
            lock.lock()
            let base = sessionBase
            let already = consumedEnd
            let delta = words.filter { $0.start >= already - 0.05 }
            if let last = delta.last { consumedEnd = max(consumedEnd, last.end) }
            lock.unlock()
            guard !delta.isEmpty else { return }
            onLocked(base, delta)

        case "transcript.done":
            lock.lock()
            state = .closed
            pingTimer?.cancel()
            lock.unlock()

        case "error":
            FileHandle.standardError.write(Data("streaming: server error: \(text)\n".utf8))

        default:
            break // transcript.created and friends
        }
    }

    private func connectionDropped() {
        lock.lock()
        if finishing || state == .closed { lock.unlock(); return }
        if disconnectAt == nil { disconnectAt = everLive ? position : 0 }
        state = .reconnecting
        pingTimer?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 15)
        lock.unlock()

        FileHandle.standardError.write(Data(
            String(format: "streaming: connection lost — reconnecting in %.0fs\n", delay).utf8
        ))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// Ping every 30s so a silently-dead connection (network drop without a
    /// close frame) is detected instead of swallowing the rest of the meeting.
    private func startPing(_ connection: URLSessionWebSocketTask) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self, weak connection] in
            guard let connection else { return }
            connection.sendPing { error in
                if error != nil { self?.connectionDropped() }
            }
        }
        timer.resume()
        lock.lock()
        pingTimer = timer
        lock.unlock()
    }
}
