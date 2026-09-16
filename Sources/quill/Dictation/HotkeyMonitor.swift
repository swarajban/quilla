import CoreGraphics
import Foundation

/// Right Option is `flagsChanged`, never keyDown — keyCode 61 (kVK_RightOption).
private let kRightOptionKeyCode: Int64 = 61

/// C entry point for the event tap. Returning nil consumes the event, so
/// right option is PTT while quill runs (left option still types accents).
/// Anything that isn't a right-option press/release passes through untouched.
private let dictationTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables slow taps; re-enable rather than dying silently. Treat
    // a dead-tap window as a key-up so we don't get stuck recording.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        DispatchQueue.main.async { monitor.forceUp() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged,
          event.getIntegerValueField(.keyboardEventKeycode) == kRightOptionKeyCode
    else { return Unmanaged.passUnretained(event) }

    // One flagsChanged per physical down and per up. Do not read
    // maskAlternate: that bit is shared with left option, so a right-option
    // release while left option is held would look like we were still down
    // and leave dictation stuck recording.
    DispatchQueue.main.async { monitor.handleRightOptionEdge() }
    return nil
}

/// Global push-to-talk via a CGEvent tap on right option: hold to talk,
/// release to paste. Requires Input Monitoring (create the tap) and
/// Accessibility (consume the key). macOS prompts on first creation; a
/// denied tap simply fails to create and the caller reports it.
final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the main queue for right-option key-down.
    var onDown: (() -> Void)?
    /// Called on the main queue for right-option key-up (and tap-death).
    var onUp: (() -> Void)?

    fileprivate(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down = false

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
        forceUp()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    fileprivate func handleRightOptionEdge() {
        down.toggle()
        if down { onDown?() } else { onUp?() }
    }

    /// Key-up without a physical release (tap died, or daemon stopping).
    func forceUp() {
        guard down else { return }
        down = false
        onUp?()
    }
}
