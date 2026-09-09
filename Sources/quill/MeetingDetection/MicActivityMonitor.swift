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
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// Candidate meeting apps: processes with live input that resolve to a
    /// user-facing app name. Daemons without one (corespeechd's Hey Siri
    /// spotting, audio drivers) can't announce a meeting by themselves.
    static func meetingAppsUsingInput() -> [(pid: pid_t, name: String)] {
        otherProcessesUsingInput().compactMap { pid in
            guard let name = appName(for: pid) else { return nil }
            // Renderer/helper processes report as e.g. "Google Chrome Helper
            // (Renderer)" — trim to the parent app's name.
            let clean = name.components(separatedBy: " Helper").first ?? name
            return (pid, clean)
        }
    }
}
