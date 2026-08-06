import Foundation

/// One timed word, provider-agnostic. Both the local (parakeet) and cloud
/// (xAI) engines translate their own word structures into this before
/// segmentation, so the grouping rules live in exactly one place.
struct TimedWord: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Group word timings into readable segments: break on sentence-ending
/// punctuation, a silence gap, or a hard length cap so a run-on speaker still
/// wraps. Shared by every engine so transcript shape doesn't depend on which
/// provider produced the words.
enum Segmentizer {
    static func segments(from words: [TimedWord]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.text.hasSuffix(".")
                || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
