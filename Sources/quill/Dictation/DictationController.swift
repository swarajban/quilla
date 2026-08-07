import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Push-to-talk dictation: the global hotkey toggles mic capture to a temp
/// file; on stop the audio is transcribed with the configured engine and the
/// text pasted at the cursor (pasteboard + synthetic ⌘V). Deliberately
/// separate from meeting sessions — no folder, no transcript.json, no
/// summary — and refused while a meeting is recording (one mic at a time).
@MainActor
final class DictationController {
    enum State {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle

    /// Menu-bar status line; nil hides it.
    var onStatus: ((String?) -> Void)?
    /// Gate checked before starting — AppController answers "no meeting in
    /// progress".
    var canStart: () -> Bool = { true }

    private let hotkey = HotkeyMonitor()
    private var mic: MicRecorder?
    private var audioURL: URL?
    /// Poll timer while waiting on Input Monitoring — permissions are usually
    /// granted from System Settings *after* first launch, so a one-shot
    /// startup failure would otherwise need a manual daemon restart.
    private var retryTimer: Timer?
    /// Prepared lazily on the first dictation and kept for the process run —
    /// parakeet's model load is far too expensive to repeat per utterance.
    private var engine: (any TranscriptionEngine)?

    /// Install the hotkey, retrying while permissions are pending. First
    /// launch typically fails (Input Monitoring not yet granted); the user
    /// grants it in System Settings minutes later, and the poll picks that up
    /// without a daemon restart. If macOS kills the process on grant instead,
    /// the LaunchAgent's KeepAlive brings us right back.
    func start() {
        hotkey.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        if hotkey.start() {
            hotkeyReady()
        } else {
            hotkeyWaiting()
        }
        sweepStaleTempFiles()
    }

    /// A process kill mid-dictation strands the temp CAF (the transcribe
    /// defer never runs) — sweep leftovers at launch.
    private func sweepStaleTempFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmp.path)
        else { return }
        for name in entries where name.hasPrefix("quill-dictation-") && name.hasSuffix(".caf") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        hotkey.stop()
        mic?.stop()
        mic = nil
        // Don't strand live mic audio in $TMPDIR on quit mid-dictation.
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
            audioURL = nil
        }
        state = .idle
    }

    private func hotkeyWaiting() {
        FileHandle.standardError.write(Data((
            "dictation: waiting for Input Monitoring permission "
                + "(System Settings → Privacy & Security) — retrying every 10s, no restart needed\n"
        ).utf8))
        onStatus?("dictation: waiting for Input Monitoring permission…")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard CGPreflightListenEventAccess() else { return }
                if self.hotkey.start() { self.hotkeyReady() }
            }
        }
    }

    private func hotkeyReady() {
        retryTimer?.invalidate()
        retryTimer = nil
        FileHandle.standardError.write(Data("dictation: caps-lock hotkey active\n".utf8))
        onStatus?("dictation ready — caps lock to talk")
        // Flash the hint, then hide it if dictation sits idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .idle = self.state else { return }
                self.onStatus?(nil)
            }
        }
    }

    // MARK: -

    private func toggle() {
        switch state {
        case .idle:
            startCapture()
        case .recording:
            stopCaptureAndTranscribe()
        case .transcribing:
            // A press during upload/transcription is noise, not a command.
            break
        }
    }

    private func startCapture() {
        guard canStart() else {
            flash("dictation unavailable — meeting pipeline busy")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-dictation-\(UUID().uuidString).caf")
        let mic = MicRecorder()
        do {
            try mic.start(writingTo: url)
        } catch {
            // MicRecorder may have already created the file before failing —
            // don't strand a partial capture.
            try? FileManager.default.removeItem(at: url)
            FileHandle.standardError.write(Data("dictation mic start failed: \(error)\n".utf8))
            notifyUser(title: "quill — dictation failed", body: "\(error)")
            return
        }
        self.mic = mic
        audioURL = url
        state = .recording
        onStatus?("● dictating · caps lock to paste")
    }

    private func stopCaptureAndTranscribe() {
        mic?.stop()
        mic = nil
        guard let url = audioURL else {
            state = .idle
            onStatus?(nil)
            return
        }
        audioURL = nil
        state = .transcribing
        onStatus?("transcribing dictation…")
        Task { [weak self] in
            await self?.transcribeAndPaste(url)
        }
    }

    private func transcribeAndPaste(_ url: URL) async {
        // A flash must outlive the reset — clearing the status here would
        // erase it in the same main-actor turn, before it ever renders.
        var statusShown = false
        defer {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            if !statusShown { onStatus?(nil) }
        }
        do {
            let engine = try await preparedEngine()
            let segments = try await engine.transcribe(url)
            let text = segments.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                statusShown = true
                flash("no speech detected")
                return
            }
            if Paster.paste(text) {
                FileHandle.standardError.write(Data("dictation pasted: \(text)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "dictation: paste needs Accessibility permission — prompt shown\n".utf8
                ))
                notifyUser(
                    title: "quill — grant Accessibility to paste",
                    body: "Privacy & Security → Accessibility → enable quill, then dictate again"
                )
            }
        } catch {
            if Self.isNoSpeech(error) {
                // Silence isn't a failure — the user just didn't say anything.
                statusShown = true
                flash("no speech detected")
            } else {
                FileHandle.standardError.write(Data("dictation failed: \(error)\n".utf8))
                notifyUser(title: "quill — dictation failed", body: "\(error)")
            }
        }
    }

    /// Empty/inaudible audio reaches us as these engine errors.
    private static func isNoSpeech(_ error: Error) -> Bool {
        if let e = error as? XAISttEngine.EngineError {
            switch e {
            case .noTranscript, .unreadableAudio: return true
            default: return false
            }
        }
        if let e = error as? ParakeetEngine.EngineError, case .unreadableAudio = e {
            return true
        }
        return false
    }

    /// Show a transient status line, cleared after a few seconds if idle.
    private func flash(_ text: String) {
        onStatus?(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .idle = self.state else { return }
                self.onStatus?(nil)
            }
        }
    }

    private func preparedEngine() async throws -> any TranscriptionEngine {
        if let engine { return engine }
        let engine: any TranscriptionEngine
        switch Config.transcriptionEngine() {
        case "xai":
            engine = XAISttEngine()
        default:
            engine = ParakeetEngine()
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }
}

/// Clipboard-mediated paste at the current cursor. Requires Accessibility
/// permission for the synthetic ⌘V — without it, posted events silently
/// no-op, so preflight first and trigger the system prompt (false return)
/// rather than pretending the paste happened. The user's previous clipboard
/// string is restored after the paste lands (rich types aren't preserved).
enum Paster {
    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard CGPreflightPostEventAccess() else {
            // kAXTrustedCheckOptionPrompt as a literal — the global isn't
            // concurrency-safe to reference under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return false
        }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenCount = pasteboard.changeCount

        // kVK_ANSI_V = 9
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        // Give the target app a beat to read the pasteboard before restoring.
        // Restore only if nothing else has written since our transcript —
        // clobbering a newer clipboard (yours or another app's) is worse than
        // leaving the transcript in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard pasteboard.changeCount == writtenCount else { return }
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }
}
