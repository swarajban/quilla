import AppKit

/// Floating always-on-top panel showing the meeting transcript as it streams
/// in — the live counterpart to transcript.md. Refreshed by the caller (once
/// a second while recording); renders the full segment list each pass, which
/// stays cheap even for hour-long meetings (~10k words).
@MainActor
final class LiveTranscriptPanel: NSPanel, NSWindowDelegate {
    private let textView: NSTextView
    /// Set by the owner; closing the panel unchecks the menu item.
    var onClose: (() -> Void)?

    init() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        super.init(
            contentRect: scroll.frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "quill — live transcript"
        isFloatingPanel = true
        level = .floating
        contentView = scroll
        delegate = self
        setFrameAutosaveName("quill.liveTranscript")
    }

    func render(_ segments: [(speaker: String, start: Double, text: String)]) {
        let out = NSMutableAttributedString()
        let speakerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        for segment in segments {
            out.append(NSAttributedString(
                string: "\(segment.speaker): ",
                attributes: [
                    .font: speakerFont,
                    .foregroundColor: segment.speaker == "me"
                        ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
            ))
            out.append(NSAttributedString(
                string: "\(segment.text)\n\n",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
            ))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
