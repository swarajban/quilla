import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let dictationLabel: NSMenuItem
    private let streamingLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let liveItem: NSMenuItem
    private let resumeItem: NSMenuItem
    private let micItem: NSMenuItem

    // Icon tint state — recording (red) wins over processing (orange).
    private var recording = false
    private var processing = false

    // Idle-silence blink: alternate the feather with a dimmed copy (same
    // image size, so the status item's width never changes and neighbours
    // don't shift). A text badge would resize the item; a tint blink would
    // be stripped by menu-bar managers like Bartender.
    private var blinking = false
    private var blinkOn = false
    private var blinkTimer: Timer?
    private var featherNormal: NSImage?
    private var featherDimmed: NSImage?

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onResume: (() -> Void)?
    /// Toggles the live transcript panel; only meaningful while a streaming
    /// recording is active (the item is hidden otherwise).
    var onToggleLive: (() -> Void)?
    /// Label for the resume item (nil hides it) — re-evaluated on menu open.
    var resumeLabel: () -> String? = { nil }

    // Mic picker plumbing — supplied by AppController.
    var micDevices: () -> [(uid: String, name: String)] = { [] }
    var selectedMicUID: () -> String? = { nil }
    var onSelectMic: ((String?) -> Void)?

    override init() {
        // NSObject init phasing: initialize all stored properties first, then
        // super.init(), and only then wire anything that references self.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dictationLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        resumeItem = NSMenuItem(
            title: "Resume last meeting",
            action: #selector(resumeClicked),
            keyEquivalent: ""
        )
        streamingLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        liveItem = NSMenuItem(
            title: "Live Transcript",
            action: #selector(liveClicked),
            keyEquivalent: "l"
        )
        micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        dictationLabel.isEnabled = false
        dictationLabel.isHidden = true
        menu.addItem(dictationLabel)

        streamingLabel.isEnabled = false
        streamingLabel.isHidden = true
        menu.addItem(streamingLabel)

        menu.addItem(.separator())

        menu.addItem(toggleItem)

        resumeItem.isHidden = true
        menu.addItem(resumeItem)

        liveItem.isHidden = true
        menu.addItem(liveItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        // Input picker; contents rebuild on every open so hotplugged mics
        // appear without a restart.
        micItem.submenu = NSMenu()
        menu.addItem(micItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, resumeItem, liveItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            featherNormal = Self.featherImage()
            featherNormal?.isTemplate = true
            featherDimmed = featherNormal.map { Self.dimmed($0, alpha: 0.25) }
            button.image = featherNormal
            button.imagePosition = .imageLeft
        }
    }

    /// Same icon at a fraction of its alpha — the blink's "off" frame.
    /// Template rendering uses the alpha channel as the mask, so a 0.25
    /// alpha draw reads as a faint feather in the menu bar.
    private static func dimmed(_ image: NSImage, alpha: CGFloat) -> NSImage {
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        image.draw(
            at: .zero,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: alpha
        )
        copy.unlockFocus()
        copy.isTemplate = true
        return copy
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        self.recording = recording
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        updateChrome()
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. While any session is transcribing/summarizing, a
    /// "…" badge appears next to the feather so a long post-meeting pipeline
    /// is visible at a glance without opening the menu. Independent of
    /// recording state — a new recording can run while the last one
    /// transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        processing = text != nil
        updateChrome()
    }

    private func updateChrome() {
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        // Text badge rather than a tint: menu-bar managers (Bartender et al.)
        // re-host status items and don't always preserve tint changes, but
        // the title always survives.
        statusItem.button?.title = processing ? "…" : ""
        // Idle blink swaps the icon, never the title — same-size images keep
        // the status item's width (and the rest of the menu bar) still.
        if blinking {
            statusItem.button?.image = blinkOn ? featherNormal : featherDimmed
        } else {
            statusItem.button?.image = featherNormal
        }
    }

    /// Streaming connection state line while recording; nil hides it.
    func updateStreaming(_ text: String?) {
        streamingLabel.title = text ?? ""
        streamingLabel.isHidden = text == nil
    }

    /// The live-transcript toggle: visible only while a streaming session can
    /// feed the panel; checked while the panel is open.
    func updateLiveItem(visible: Bool, checked: Bool) {
        liveItem.isHidden = !visible
        liveItem.state = checked ? .on : .off
    }

    /// Blink the status item to flag a silent (possibly abandoned) meeting.
    func setBlinking(_ on: Bool) {
        guard on != blinking else { return }
        blinking = on
        blinkTimer?.invalidate()
        blinkTimer = nil
        if on {
            blinkOn = true
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.updateChrome()
                }
            }
        }
        updateChrome()
    }

    /// Show dictation state (hotkey hint / dictating / transcribing) as a
    /// status line; nil hides it.
    func updateDictation(_ text: String?) {
        dictationLabel.title = text ?? ""
        dictationLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func resumeClicked() { onResume?() }
    @objc private func liveClicked() { onToggleLive?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }

    @objc private func micClicked(_ sender: NSMenuItem) {
        onSelectMic?(sender.representedObject as? String)
    }

    /// Rebuild the mic submenu each time the menu opens: "System default"
    /// plus every current input device, checked on the selection.
    private func rebuildMicMenu() {
        guard let submenu = micItem.submenu else { return }
        submenu.removeAllItems()
        let selected = selectedMicUID()
        let items: [(String, String?)] = [("System default", nil)]
            + micDevices().map { ($0.name, Optional($0.uid)) }
        for (title, uid) in items {
            let item = NSMenuItem(
                title: title, action: #selector(micClicked(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = uid
            item.state = uid == selected ? .on : .off
            submenu.addItem(item)
        }
    }
}

extension MenuBarController: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            rebuildMicMenu()
            // The resume label embeds "(Nm ago)" — refresh it on every open.
            let label = resumeLabel()
            resumeItem.title = label ?? "Resume last meeting"
            resumeItem.isHidden = label == nil
        }
    }
}
