import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Meeting recorder + transcriber. Records mic and system audio as two tracks, transcribes via xAI cloud (default) or on-device parakeet, then summarizes with an LLM.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let dictation = DictationController()
    private var session: RecordingSession?
    private var ticker: Timer?
    /// True while the transcription queue has work — dictation stays out of
    /// the way of the meeting pipeline entirely (recording OR processing).
    private var transcriptionActive = false

    /// Idle-meeting handling (streaming sessions only): blink the menu icon
    /// after this much silence on both tracks, hard-stop after the longer
    /// threshold — an idle meeting leaves a WebSocket connection open and a
    /// red recording indicator burning for nothing.
    private static let idleBlinkSeconds: TimeInterval = 15
    private static let idleStopSeconds: TimeInterval = 300
    /// How long a stopped meeting stays resumable from the menu.
    private static let resumeWindow: TimeInterval = 30 * 60
    private var idleTimer: Timer?
    /// Last stopped session, offered as "Resume last meeting" in the menu.
    private var resumable: (dir: URL, stoppedAt: Date)?

    // Live transcript panel: persists its open/closed preference across
    // sessions within the process; refreshes once a second from the
    // streaming session's locked words.
    private var livePanel: LiveTranscriptPanel?
    private var liveTimer: Timer?
    private var liveWanted = false

    init(root: URL) {
        self.root = root
        Notify.onOpen = { [weak self] in self?.openFolder() }
        Notify.configure()
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onResume = { [weak self] in self?.resumeSession() }
        menuBar.resumeLabel = { [weak self] in self?.resumeLabelText() }
        menuBar.onToggleLive = { [weak self] in self?.toggleLivePanel() }
        menuBar.micDevices = { InputDevices.inputs().map { ($0.uid, $0.name) } }
        menuBar.selectedMicUID = { InputDevices.selectedUID }
        menuBar.onSelectMic = { uid in InputDevices.selectedUID = uid }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        if Config.dictationEnabled() {
            dictation.canStart = { [weak self] in
                guard let self else { return true }
                return self.session == nil && !self.transcriptionActive
            }
            dictation.onStatus = { [weak self] status in
                self?.menuBar.updateDictation(status)
            }
            dictation.start()
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        dictation.stop()
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            promptForName()
        } else {
            stopSession()
        }
    }

    /// Optional-name prompt on the way into a recording. The combo box is
    /// editable and preloaded with names used by previous sessions so recurring
    /// meetings are a pick, not a retype. Cancelling aborts the start.
    private func promptForName() {
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = "Optional — becomes the session folder name, e.g. \"2026-08-06-1430-team-sync\"."

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
        combo.isEditable = true
        combo.completes = true
        combo.numberOfVisibleItems = 8
        combo.addItems(withObjectValues: Array(RecentNames.list(from: root).prefix(20)))
        alert.accessoryView = combo
        alert.addButton(withTitle: "Start recording")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = combo

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        startSession(name: raw.isEmpty ? nil : raw)
    }

    private func startSession(name: String?, resumeInto: URL? = nil) {
        do {
            let newSession = try resumeInto.map { try RecordingSession(resumeInto: $0) }
                ?? RecordingSession(root: root, name: name)
            try newSession.start()
            session = newSession
            resumable = nil
            FileHandle.standardError.write(Data(
                "● recording → \(newSession.dir.path)\(resumeInto != nil ? " (resumed)" : "")\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if session?.streaming != nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
            if liveWanted { showLivePanel() }
        }
        menuBar.updateLiveItem(visible: session?.streaming != nil, checked: liveWanted)
    }

    private func toggleLivePanel() {
        liveWanted.toggle()
        if liveWanted, session?.streaming != nil {
            showLivePanel()
        } else {
            livePanel?.close()
            livePanel = nil
            liveTimer?.invalidate()
            liveTimer = nil
        }
        menuBar.updateLiveItem(visible: session?.streaming != nil, checked: liveWanted)
    }

    private func showLivePanel() {
        if livePanel == nil {
            let panel = LiveTranscriptPanel()
            panel.onClose = { [weak self] in
                // Window close = uncheck the menu item.
                self?.liveWanted = false
                self?.livePanel = nil
                self?.liveTimer?.invalidate()
                self?.liveTimer = nil
                self?.menuBar.updateLiveItem(
                    visible: self?.session?.streaming != nil, checked: false)
            }
            livePanel = panel
        }
        livePanel?.orderFront(nil)
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLivePanel() }
        }
    }

    private func refreshLivePanel() {
        guard let panel = livePanel, panel.isVisible,
              let streaming = session?.streaming
        else { return }
        panel.render(streaming.liveSegments())
    }

    /// Resume the last stopped meeting in its original folder, continuing the
    /// timeline and re-running the transcript/summary over the whole meeting.
    private func resumeSession() {
        guard let target = resumable, session == nil else { return }
        startSession(name: nil, resumeInto: target.dir)
    }

    private func resumeLabelText() -> String? {
        guard let target = resumable, session == nil else { return nil }
        let ago = Date().timeIntervalSince(target.stoppedAt)
        guard ago < Self.resumeWindow else { return nil }
        return "Resume last meeting (\(Int(ago / 60))m ago)"
    }

    /// Silence watchdog for streaming sessions: warn (blink) at 15s, stop the
    /// meeting at 5min so we never hold an idle connection/recording open.
    private func checkIdle() {
        guard let session, let idle = session.streaming?.idleSeconds else { return }
        if idle >= Self.idleStopSeconds {
            FileHandle.standardError.write(Data(
                "auto-stop: \(Int(idle))s of silence on both tracks\n".utf8
            ))
            notifyUser(
                title: "quill — meeting auto-stopped",
                body: "5 minutes of silence. It stays resumable from the menu for 30 minutes."
            )
            stopSession()
        } else {
            menuBar.setBlinking(idle >= Self.idleBlinkSeconds)
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        idleTimer?.invalidate()
        idleTimer = nil
        menuBar.setBlinking(false)
        menuBar.updateStreaming(nil)
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateLiveItem(visible: false, checked: liveWanted)
        livePanel?.close()
        livePanel = nil
        liveTimer?.invalidate()
        liveTimer = nil
        resumable = (dir: session.dir, stoppedAt: Date())

        let dir = session.dir
        // Drain streaming finals before the pipeline reads the JSONL.
        Task { [transcription] in
            await session.finishStreaming()
            await transcription.enqueue(dir)
        }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            transcriptionActive = false
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            transcriptionActive = true
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            transcriptionActive = false
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
        menuBar.updateStreaming(session.streaming.map { "streaming: \($0.stateDescription)" })
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Names used by prior sessions, newest first. Derived from the recordings
/// root itself (folder names embed the name), so there's no separate state
/// file to keep in sync.
enum RecentNames {
    static func list(from root: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        // Timestamp-first folder names sort chronologically, newest first.
        for dir in entries
            .map(\.lastPathComponent)
            .sorted(by: >)
        {
            guard let name = RecordingSession.name(from: dir), !seen.contains(name) else {
                continue
            }
            seen.insert(name)
            names.append(name)
        }
        return names
    }
}
