import CoreGraphics
import Foundation

/// Caps Lock is `flagsChanged`, never keyDown — keyCode 57 (kVK_CapsLock).
private let kCapsLockKeyCode: Int64 = 57

/// C entry point for the event tap. Returning nil consumes the event, so the
/// system never actually toggles caps lock while quill runs with dictation
/// enabled. Anything that isn't a caps-lock press passes through untouched.
private let dictationTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables slow taps; re-enable rather than dying silently.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged,
          event.getIntegerValueField(.keyboardEventKeycode) == kCapsLockKeyCode
    else { return Unmanaged.passUnretained(event) }

    DispatchQueue.main.async { monitor.onPress?() }
    return nil
}

/// Global push-to-talk hotkey via a CGEvent tap on caps lock. Each physical
/// press is one flagsChanged event, so the monitor just alternates: press to
/// start, press again to stop. Requires Input Monitoring to create the tap
/// and Accessibility to consume events / post the paste keystroke — macOS
/// prompts on first creation; a denied tap simply fails to create and the
/// caller reports it.
final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the main queue for every caps-lock press.
    var onPress: (() -> Void)?

    fileprivate(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Install the tap on the main run loop. False = permission missing
    /// (Input Monitoring denied or not yet granted). Requesting listen access
    /// first so macOS actually shows its prompt instead of the tap silently
    /// failing to create.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
            callback: dictationTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        // commonModes: the hotkey still fires while a menu is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }
}
