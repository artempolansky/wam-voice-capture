import Foundation

/// Common interface for speech-to-text providers.
///
/// Two implementations:
///   - ``DeepgramClient`` — cloud, low-latency streaming, requires network
///   - ``WhisperLocalClient`` — on-device whisper.cpp, fully offline,
///     batch-processed (higher latency, no streaming partials)
///
/// The protocol mirrors Deepgram's lifecycle because that's the older /
/// streaming-shaped API; local providers fake the streaming contract by
/// buffering audio and only emitting transcripts on ``finish()`` or at
/// chunk boundaries.
///
/// Lifecycle:
/// ```
///   client.onTranscript = { … }    // wire up callbacks
///   client.onError      = { … }
///   client.connect()                // open connection / start engine
///   client.sendAudio(chunk)         // repeated during the session
///   client.finish()                 // signal end → final transcripts arrive
///   client.disconnect()             // tear down
/// ```
protocol STTProvider: AnyObject {
    /// Fires for every partial / final transcript the provider emits.
    /// Streaming providers fire many times; batch providers (Whisper)
    /// fire once on ``finish()`` (or per chunk if chunking is enabled).
    var onTranscript: ((STTTranscript) -> Void)? { get set }

    /// Provider-level errors (network, model load, subprocess crash).
    var onError: ((Error) -> Void)? { get set }

    /// Connection established (streaming) or engine ready (batch).
    /// For batch providers this fires immediately after ``connect()``.
    var onOpen: (() -> Void)? { get set }

    /// Provider closed. ``code`` and ``reason`` follow the WebSocket
    /// convention (``code=1000`` = normal close). Batch providers
    /// synthesize ``1000`` / empty reason on disconnect.
    var onClose: ((Int, String) -> Void)? { get set }

    /// Open the underlying transport. Idempotent.
    func connect()

    /// Push a chunk of audio. Format: 16 kHz Int16 mono (single-channel
    /// providers) or interleaved stereo (multichannel providers).
    /// Buffered until ``connect()`` completes.
    func sendAudio(_ pcm: Data)

    /// Signal end of audio. Streaming providers flush + emit finals;
    /// batch providers run inference now and emit final transcript(s).
    func finish()

    /// Abort and release resources. Safe to call after ``finish()`` or
    /// instead of it.
    func disconnect()
}


/// One transcript event from any STT provider.
///
/// Streaming providers emit multiple of these per session (with
/// ``isFinal`` flipping from false to true). Batch providers emit
/// exactly one per chunk / session with ``isFinal == true``.
struct STTTranscript {
    /// Recognized text. Empty on interim events that had no content yet.
    let text: String

    /// True if this is the finalized text for an utterance. Streaming
    /// providers emit ``isFinal == false`` partials while the user
    /// speaks, then a final once silence is detected.
    let isFinal: Bool

    /// 0 for mic / left channel, 1 for system audio / right channel,
    /// nil for mono providers. Used by ``MeetingSession`` to route
    /// transcripts into Speaker 1 vs Speaker 2+ buckets.
    let channelIndex: Int?

    /// Per-word breakdown with speaker IDs (diarization). Empty for
    /// providers that don't diarize (Whisper local, Apple Speech) or
    /// for interim events.
    let words: [STTWord]
}


/// One word inside an ``STTTranscript`` with timing + optional
/// diarization label.
struct STTWord {
    let text: String

    /// Provider-specific speaker label. Deepgram emits 0/1/2 within
    /// each channel; Whisper local emits nil (no diarization). Treat
    /// as opaque — ``SpeakerLabels`` resolves to user-visible labels.
    let speaker: Int?

    let start: Double
    let end: Double
}
