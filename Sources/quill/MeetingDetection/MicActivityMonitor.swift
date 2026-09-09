import AppKit
import CoreAudio
import Foundation

/// Detects other processes with live audio input — the calendar-free signal
/// that a meeting is probably happening (Zoom/Teams/Meet-in-browser/… hold
/// the mic open; music and videos don't). Uses the macOS 14.2+ CoreAudio
/// process-object API; needs no microphone permission itself (this is
/// hardware state, not audio content).
enum MicActivityMonitor {

    /// PIDs (excluding ours) that currently have a running audio input.
    static func otherProcessesUsingInput() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var pids: [pid_t] = []
        for object in objects {
            var runningInput: UInt32 = 0
            var propSize = UInt32(MemoryLayout<UInt32>.size)
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                object, &inputAddress, 0, nil, &propSize, &runningInput
            ) == noErr, runningInput != 0 else { continue }

            var pid: pid_t = 0
            propSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                object, &pidAddress, 0, nil, &propSize, &pid
            ) == noErr, pid != selfPID else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// Display name for a pid, for the notification body ("Zoom", "Google
    /// Chrome" — a browser usually means Meet/Teams web).
    static func appName(for pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            // Renderer processes report as e.g. "Google Chrome Helper
            // (Renderer)" — trim to the parent app's name.
            return name.components(separatedBy: " Helper").first ?? name
        }
        // Helpers/plugins don't register with NSRunningApplication — derive
        // the host app from the executable path's outermost .app bundle.
        // Daemons outside any .app (corespeechd, drivers) stay nameless.
        guard let path = executablePath(for: pid) else { return nil }
        for component in path.components(separatedBy: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return nil
    }

    /// Full executable path via `ps` (libproc isn't exposed to Swift without
    /// a bridging header; this runs at most per detection poll per pid).
    private static func executablePath(for pid: pid_t) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "comm="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard let _ = try? task.run() else { return nil }
        task.waitUntilExit()
        let path = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Candidate meeting apps: processes with live input that resolve to a
    /// user-facing app name. Daemons without one (corespeechd's Hey Siri
    /// spotting, audio drivers) can't announce a meeting by themselves.
    static func meetingAppsUsingInput() -> [(pid: pid_t, name: String)] {
        otherProcessesUsingInput().compactMap { pid in
            guard let name = appName(for: pid) else { return nil }
            return (pid, name)
        }
    }
}
