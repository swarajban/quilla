import AVFoundation
import Foundation

/// Cloud speech-to-text via xAI's Groq-compatible STT API
/// (POST /v1/stt, about $0.10/hr of audio). Unlike parakeet there is no model
/// to download or hold — each track is converted to M4A (CAF isn't a
/// supported upload container) and posted once, then released. On-device
/// nothing; privately attributed mic/system tracks still go out as separate
/// clean single-source files.
actor XAISttEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case missingKey
        case unreadableAudio(URL, Error?)
        case conversionFailed(Error)
        case requestFailed(Int, String)
        case noTranscript

        var description: String {
            switch self {
            case .missingKey:
                return "no xAI API key — add \"api_keys\": {\"xai\": \"...\"} to ~/.config/quill/config.json or export XAI_API_KEY"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            case .conversionFailed(let e): return "CAF → M4A conversion failed: \(e)"
            case .requestFailed(let s, let body):
                return "xAI STT request failed (HTTP \(s)): \(body)"
            case .noTranscript: return "xAI STT returned no text"
            }
        }
    }

    nonisolated let name = "xai"
    nonisolated let model = "xai-stt"

    private let baseURL: URL
    private let session: URLSession

    init() {
        self.baseURL = URL(string: "https://api.x.ai/v1")!
        self.session = HTTPClient.session()
    }

    func prepare() async throws {
        guard Config.apiKey("XAI") != nil else { throw EngineError.missingKey }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let key = Config.apiKey("XAI") else { throw EngineError.missingKey }

        // Same guard as parakeet: a track with no frames raises an uncatchable
        // ObjC exception inside AVAudioFile's resampler, so probe first.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        let m4aURL = try await Self.convertToM4A(audio)
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        var request = URLRequest(url: baseURL.appendingPathComponent("stt"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            language: Config.transcriptionLanguage(),
            keyTerms: Config.transcriptionKeyTerms(),
            fileURL: m4aURL
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.requestFailed(-1, "no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw EngineError.requestFailed(http.statusCode, Self.errorBody(data))
        }

        let result = try JSONDecoder().decode(STTResponse.self, from: data)
        guard let words = result.words, !words.isEmpty else {
            let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw EngineError.noTranscript }
            return [TranscriptSegment(start: 0, end: result.duration ?? 0, text: text)]
        }
        return Segmentizer.segments(from: words.map {
            TimedWord(text: $0.text, start: $0.start, end: $0.end)
        })
    }

    func release() async {}

    // MARK: -

    /// Re-encode a CAF track as M4A (AAC in MPEG-4) for upload. CAF is not in
    /// the API's supported container list; M4A keeps the same codec and
    /// channels, so a 1-hour meeting stays a few megabytes.
    static func convertToM4A(_ caf: URL) async throws -> URL {
        do {
            let src = try AVAudioFile(forReading: caf)
            let srcFormat = src.processingFormat
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-\(UUID().uuidString).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: srcFormat.sampleRate,
                AVNumberOfChannelsKey: srcFormat.channelCount,
            ]
            let outFile = try AVAudioFile(
                forWriting: outURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            let capacity = AVAudioFrameCount(32768)
            guard let inBuffer = AVAudioPCMBuffer(
                pcmFormat: srcFormat, frameCapacity: capacity
            ) else { throw EngineError.conversionFailed(Self.bufferError) }

            let converter: AVAudioConverter?
            if srcFormat == outFile.processingFormat {
                converter = nil
            } else {
                guard let conv = AVAudioConverter(
                    from: srcFormat, to: outFile.processingFormat
                ) else { throw EngineError.conversionFailed(Self.bufferError) }
                converter = conv
            }

            // read(into:) is a moving target across SDKs: it used to signal EOF
            // with a 0-frame return, and newer releases throw at end of file
            // (returning Void). Handle both, plus the converter for sample-rate
            // or bit-depth mismatches.
            while true {
                do {
                    try src.read(into: inBuffer)
                } catch {
                    break
                }
                let count = inBuffer.frameLength
                guard count > 0 else { break }
                if let converter {
                    guard let outBuffer = AVAudioPCMBuffer(
                        pcmFormat: outFile.processingFormat,
                        frameCapacity: AVAudioFrameCount(count)
                    ) else { throw EngineError.conversionFailed(Self.bufferError) }
                    try converter.convert(to: outBuffer, from: inBuffer)
                    try outFile.write(from: outBuffer)
                } else {
                    try outFile.write(from: inBuffer)
                }
            }
            return outURL
        } catch {
            throw EngineError.conversionFailed(error)
        }
    }

    private static var bufferError: Error {
        NSError(domain: "quill", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "couldn't allocate conversion buffer"
        ])
    }

    /// multipart/form-data with `language` + `format` fields before the file —
    /// (and repeated `keyterm` fields when key terms are configured)
    /// the API requires `file` last, and fields after it may be ignored.
    static func multipartBody(
        boundary: String, language: String, keyTerms: [String], fileURL: URL
    ) -> Data {
        var body = Data()
        body.append(Self.part("language", value: language, boundary: boundary))
        body.append(Self.part("format", value: "true", boundary: boundary))
        // `keyterm` (repeatable): biases recognition toward the listed
        // vocabulary so names/jargon come out spelled right. The API enforces
        // max 100 terms of 50 chars each with a 400, so clamp defensively.
        // (The Whisper-style `prompt` field is accepted but inert — probed.)
        var terms = keyTerms
        if terms.count > 100 {
            FileHandle.standardError.write(Data(
                "warning: transcription.key_terms has \(terms.count) entries — using first 100 (API limit)\n".utf8
            ))
            terms = Array(terms.prefix(100))
        }
        for term in terms {
            body.append(Self.part(
                "keyterm", value: String(term.prefix(50)), boundary: boundary))
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append((try? Data(contentsOf: fileURL)) ?? Data())
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    static func part(_ name: String, value: String, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
        return body
    }

    /// Best-effort extraction of the API's error message from a non-2xx body;
    /// falls back to a short raw snippet so the failure is diagnosable.
    private static func errorBody(_ data: Data) -> String {
        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? String
                ?? (json["error"] as? String)
                ?? (json["error"] as? [String: Any])?["message"] as? String
        {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return String(raw.prefix(300))
    }
}

private struct STTResponse: Decodable {
    let text: String?
    let duration: Double?
    let words: [Word]?

    struct Word: Decodable {
        let text: String
        let start: Double
        let end: Double
    }
}
