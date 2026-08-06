import Foundation

/// Single URL transport used by every cloud call (xAI STT, LLM summarization).
/// Sits behind one builder so tests can inject a mock `URLProtocol` — mutating
/// `URLSessionConfiguration.default` directly is unreliable because each read
/// can return a fresh configuration, silently dropping the override.
enum HTTPClient {
    nonisolated(unsafe) static var injectedProtocolClasses: [AnyClass] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.protocolClasses = injectedProtocolClasses + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}
