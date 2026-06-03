import Foundation

/// User's choice of STT provider, persisted in ``UserDefaults`` and used
/// by ``LocalCaptureSession`` / ``MeetingSession`` to pick the right
/// implementation when starting a session.
///
/// Stored as a string so future providers (Apple Speech, Whisper-cloud, …)
/// can be added without a migration.
@MainActor
final class STTSettings {

    static let shared = STTSettings()

    enum Provider: String, CaseIterable {
        /// Deepgram cloud streaming. Lowest latency, supports diarization,
        /// requires network.
        case deepgram = "Deepgram"

        /// On-device whisper.cpp via the brew-installed ``whisper-cli`` CLI.
        /// Fully offline. Batch-processed: no streaming partials, the
        /// final transcript arrives after ``finish()``.
        case whisperLocal = "Local Whisper"
    }

    private let defaultsKey = "WAMSTTProvider"

    var currentProvider: Provider {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let p = Provider(rawValue: raw) {
                return p
            }
            return .deepgram   // legacy default — keeps existing users working
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            TrayLog.append("stt: provider set to \(newValue.rawValue)")
        }
    }

    /// Factory: build an STT provider per the user's current selection.
    ///
    /// All parameters are interpreted by ``DeepgramClient`` (Whisper-local
    /// ignores ``multichannel`` and ``diarize``; channel mixing is still
    /// honored — the audio mixer still interleaves mic+system into stereo).
    func makeProvider(apiKey: String,
                      channels: Int,
                      multichannel: Bool,
                      diarize: Bool) -> STTProvider {
        switch currentProvider {
        case .deepgram:
            return DeepgramClient(
                apiKey: apiKey,
                channels: channels,
                multichannel: multichannel,
                diarize: diarize
            )
        case .whisperLocal:
            return WhisperLocalClient(channels: channels)
        }
    }

    /// True if the currently-selected provider is actually usable. If
    /// false, the tray menu nudges the user to install it (or pick the
    /// other one). For Whisper: checks whisper-cli + model file presence.
    var currentProviderReady: Bool {
        switch currentProvider {
        case .deepgram:
            return (try? KeychainHelper.deepgramAPIKey())
                .map { !$0.isEmpty } ?? false
        case .whisperLocal:
            return WhisperLocalClient.isInstalled && WhisperLocalClient.modelExists
        }
    }
}
