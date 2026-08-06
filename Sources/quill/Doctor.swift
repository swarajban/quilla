import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkSummary(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model (or API key) after an important meeting:
    /// report what the configured engine needs to actually transcribe.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        if Config.transcriptionEngine() == "xai" {
            guard Config.apiKey("XAI") != nil else {
                return Check(
                    name: "transcription",
                    status: .warn("xai engine configured but no API key — recordings will not be transcribed"),
                    remediation: "add \"api_keys\": {\"xai\": \"...\"} to ~/.config/quill/config.json (chmod 600) or export XAI_API_KEY"
                )
            }
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    /// Summaries silently skip on a missing key; surface that before a user
    /// wonders why there's no summary.md.
    static func checkSummary() -> Check {
        guard Config.summaryEnabled() else {
            return Check(
                name: "summary",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let provider = Config.summaryProvider()
        guard Config.apiKey(provider) != nil else {
            return Check(
                name: "summary",
                status: .warn("\(provider) provider configured but no API key — summaries will be skipped"),
                remediation: "add \"api_keys\": {\"\(provider)\": \"...\"} to ~/.config/quill/config.json (chmod 600) or export \(provider.uppercased())_API_KEY"
            )
        }
        return Check(name: "summary", status: .ok, remediation: nil)
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
