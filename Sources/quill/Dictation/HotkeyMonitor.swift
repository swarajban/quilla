import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

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
    // Consume only for an active tap. listen-only must pass the event through.
    if monitor.consumesEvents { return nil }
    return Unmanaged.passUnretained(event)
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
    /// True when the tap is `.defaultTap` (event is swallowed). False for
    /// listen-only, where right option still behaves as Option.
    fileprivate(set) var consumesEvents = false
    private var source: CFRunLoopSource?
    private var down = false

    /// Install the tap on the main run loop. False = permission missing.
    /// `IOHIDRequestAccess` is what actually shows the Input Monitoring
    /// prompt on modern macOS; `CGRequestListenEventAccess` often does not.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        requestPermissions()
        if installTap(options: .defaultTap) {
            consumesEvents = true
            return true
        }
        // Active tap needs Accessibility. Listen-only still sees the key and
        // is what puts quill on the Input Monitoring list.
        if installTap(options: .listenOnly) {
            consumesEvents = false
            FileHandle.standardError.write(Data(
                "dictation: listen-only tap (grant Accessibility to consume right option)\n".utf8
            ))
            return true
        }
        return false
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
        consumesEvents = false
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

    private func requestPermissions() {
        // Accessory apps often cannot present TCC alerts. Promote briefly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
        if !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        NSApp.setActivationPolicy(.accessory)
    }

    private func installTap(options: CGEventTapOptions) -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
            callback: dictationTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}
