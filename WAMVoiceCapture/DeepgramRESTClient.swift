import Foundation

/// One-shot Deepgram transcription over plain HTTPS POST — the fallback
/// path for dictation when the streaming WebSocket cannot be established
/// (VPN blips kill the long-lived socket far more often than a single
/// short request).
///
/// Not used for meetings: an hour of PCM is too large for one POST and
/// the streaming path there already survives blips via reconnect-with-
/// backoff (v1.0.3).
enum DeepgramRESTClient {

    enum RESTError: LocalizedError {
        case badStatus(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return "Deepgram REST failed (HTTP \(code)): \(body)"
            case .emptyResponse:
                return "Deepgram REST returned no transcript"
            }
        }
    }

    /// Transcribe a buffer of raw 16 kHz mono Int16 PCM in one request.
    /// Mirrors the streaming path's parameters (nova-3, ru, smart_format,
    /// punctuate) so quality is identical to a healthy WebSocket session.
    static func transcribe(pcm: Data,
                           apiKey: String,
                           language: String = "ru",
                           model: String = "nova-3",
                           timeout: TimeInterval = 8) async throws -> String {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = pcm

        // Ephemeral session: no shared connection pool — a poisoned keep-alive
        // connection from a VPN flap must not sabotage this request (same
        // reasoning as DeepgramClient's ephemeral configuration).
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw RESTError.badStatus(code, body)
        }

        // Response shape: results.channels[0].alternatives[0].transcript
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String
        else {
            throw RESTError.emptyResponse
        }

        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
