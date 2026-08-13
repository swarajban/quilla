import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// Caps Lock is `flagsChanged`, never keyDown — keyCode 57 (kVK_CapsLock).
private let kCapsLockKeyCode: Int64 = 57

/// Tags synthetic events quill posts itself (the latch-clear). The tap must
/// let these through untouched — consuming them would defeat the clear.
private let kSelfHealMagic: Int64 = 0x51554C4C  // "QULL"

/// C entry point for the event tap. Returning nil consumes the event, so the
/// system never actually toggles caps lock while quill runs with dictation
/// enabled. Anything that isn't a caps-lock press passes through untouched.
private let dictationTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables slow taps; re-enable rather than dying silently. While
    // the tap was dead, events flowed straight to the system — a caps-lock
    // press in that window left the real latch on, so heal it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        DispatchQueue.main.async { monitor.resyncLatch() }
        return Unmanaged.passUnretained(event)
    }

    // Our own synthetic latch-clear — must reach the system untouched.
    if event.getIntegerValueField(.eventSourceUserData) == kSelfHealMagic {
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
/// start, press again to stop. Requires Input Monitoring (and, because the
/// tap consumes events, Accessibility) — macOS prompts on first creation; a
/// denied tap simply fails to create and the caller reports it.
///
/// Caps lock is a latching key, and the tap only sees events while it's
/// alive: a second keyboard plugging in (macOS re-syncs LED state across
/// keyboards) or a tap-disabled window can flip the system latch behind our
/// back, after which typing comes out SHOUTING and presses look inverted.
/// The latch is never legitimately on while dictation owns the key, so a
/// watchdog (poll + keyboard-hotplug + tap-recovery) clears it.
final class HotkeyMonitor: @unchecked Sendable {
    /// Called on the main queue for every caps-lock press.
    var onPress: (() -> Void)?

    fileprivate(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pollTimer: Timer?
    private var hidManager: IOHIDManager?

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
        armLatchGuards()
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
        pollTimer?.invalidate()
        pollTimer = nil
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(
                hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.hidManager = nil
        }
    }

    // MARK: - Latch watchdog

    private func armLatchGuards() {
        resyncLatch()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.resyncLatch()
        }

        // Keyboard hotplug triggers macOS's cross-keyboard caps-lock LED sync,
        // which can flip the latch without a tap-visible event.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            // Let the OS finish its LED sync before checking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                monitor.resyncLatch()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    /// If the real caps-lock latch is on, post one synthetic flagsChanged
    /// with the alphaShift bit clear to flip it off. The magic user-data tag
    /// tells our own tap to pass it through instead of consuming it.
    func resyncLatch() {
        // hidSystemState, not combinedSessionState: session-posted synthetic
        // events (any macro tool) must not be able to trigger a clear, and
        // both real stray-latch causes (tap gap, keyboard LED sync) are HID.
        let realFlags = CGEventSource.flagsState(.hidSystemState)
        guard realFlags.contains(.maskAlphaShift) else { return }
        FileHandle.standardError.write(Data("dictation: clearing stray caps-lock latch\n".utf8))
        // No public flagsChanged constructor — make a key event and flip its
        // type (CGEvent.type is mutable). Flags carry the resulting modifier
        // state: alphaShift absent = latch off.
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: UInt16(kCapsLockKeyCode),
            keyDown: true
        ) else { return }
        event.type = .flagsChanged
        // Preserve the real modifier state minus the latch bit — flags=[]
        // would broadcast a spurious all-modifiers-released blip to apps
        // tracking held Shift/Cmd.
        event.flags = realFlags.subtracting(.maskAlphaShift)
        event.setIntegerValueField(.eventSourceUserData, value: kSelfHealMagic)
        event.post(tap: .cghidEventTap)
    }
}
