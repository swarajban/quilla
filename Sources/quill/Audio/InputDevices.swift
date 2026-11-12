import CoreAudio
import Foundation
import IOKit

/// Input-device discovery and selection for the mic picker in the menu bar.
/// Pure CoreAudio: AVCaptureDevice doesn't expose the AudioObjectID that
/// AVAudioEngine's input node needs, so we enumerate the HAL directly.
enum InputDevices {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// The menu-bar mic selection, persisted across launches. nil = system
    /// default input device.
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: "micDeviceUID") }
        set { UserDefaults.standard.set(newValue, forKey: "micDeviceUID") }
    }

    /// Every audio device with at least one input channel.
    static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    /// A closed lid disconnects the built-in mic in hardware, but the device
    /// stays listed and binds fine — it then delivers silence or no frames at
    /// all. Callers skip such a device for the system default. Matched by UID,
    /// not transport type: a wired headset in the jack is also "built-in" and
    /// keeps working with the lid closed.
    static func isMutedByClosedLid(_ device: Device) -> Bool {
        device.uid == "BuiltInMicrophoneDevice" && lidClosed()
    }

    private static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        return state as? Bool ?? false
    }

    // MARK: -

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value
        else { return nil }
        // HAL string properties are returned at +1 (Create rule) — retained,
        // or every menu open leaks one CFString per device.
        return cf.takeRetainedValue() as String
    }
}
