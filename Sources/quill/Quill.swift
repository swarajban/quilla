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
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
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

    private func startSession(name: String?) {
        do {
            let newSession = try RecordingSession(root: root, name: name)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
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
