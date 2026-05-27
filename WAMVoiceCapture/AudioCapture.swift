import Foundation
import AVFoundation

/// Always-on microphone capture via AVAudioEngine. Delivers 16kHz mono Int16 PCM
/// chunks (20ms, 320 frames) to all live subscribers, and maintains a rolling
/// ring-buffer of the last `preRollSeconds` seconds so a new session can send
/// pre-roll before live streaming begins.
///
/// Not `@MainActor` — the AVAudioEngine tap callback fires on the audio render
/// thread. Engine lifecycle (`ensureRunning`, `setDeviceUID`) is only called
/// from main; shared state (`ring`, `subscribers`, `pendingBuffer`) is protected
/// by `lock`.
final class AudioCapture {

    static let shared = AudioCapture()

    typealias SubscriptionID = UUID

    var onError: ((Error) -> Void)?
    /// Fires when mic availability flips. Always called on main.
    var onAvailabilityChange: ((Bool) -> Void)?
    /// Fires only when the silence-probe cycle exhausted every candidate and
    /// no working mic was found. Successful auto-fallbacks are silent — the
    /// caller doesn't need a UI signal because recording works.
    var onAllMicsFailed: (() -> Void)?
    /// Fires when a working mic is found *after* a previous total-failure
    /// state — used by the UI to clear the MIC badge.
    var onMicsRecovered: (() -> Void)?

    /// True iff the engine is currently running and producing audio.
    private(set) var isAvailable: Bool = false {
        didSet {
            if oldValue != isAvailable {
                let v = isAvailable
                DispatchQueue.main.async { [weak self] in
                    self?.onAvailabilityChange?(v)
                }
            }
        }
    }

    /// `nil` = use system default.
    private(set) var currentDeviceUID: String?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private let targetSampleRate: Double = 16000
    private let targetChunkFrames: AVAudioFrameCount = 320  // 20ms at 16kHz
    private let targetBytesPerFrame: Int = MemoryLayout<Int16>.size

    /// Pre-roll window. 1.5s × 16000 × 2 bytes ≈ 48 KB.
    let preRollSeconds: Double = 1.5
    private var ringMaxBytes: Int { Int(preRollSeconds * targetSampleRate) * targetBytesPerFrame }

    private let lock = NSLock()
    private var ring = Data()
    private var pendingBuffer = Data()
    private var subscribers: [SubscriptionID: (Data) -> Void] = [:]

    enum CaptureError: LocalizedError {
        case noInputDevice
        case selectedDeviceMissing(uid: String)
        case formatUnsupported(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:                  return "No audio input device available"
            case .selectedDeviceMissing(let uid):  return "Selected mic not connected (uid=\(uid))"
            case .formatUnsupported(let s):        return "Unsupported input format: \(s)"
            case .engineStartFailed(let s):        return "Audio engine failed to start: \(s)"
            }
        }
    }

    private init() {
        if let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) { self.targetFormat = fmt }

        // AVAudioEngine fires this when the audio device set changes — e.g. user
        // unplugs the wireless receiver. Engine stops itself; we try to recover.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        // On-demand mode quirk: when we just stopped the engine, AVAudioEngine
        // tears down its internal aggregate device. macOS fires
        // AVAudioEngineConfigurationChange in response, which used to make us
        // auto-restart the engine here — kicking the menubar mic indicator
        // back on indefinitely. Now: only restart if the engine was running
        // when the change arrived. A stopped engine STAYS stopped.
        guard engine.isRunning else {
            TrayLog.append("audio: configuration change ignored (engine idle in on-demand mode)")
            return
        }
        TrayLog.append("audio: configuration change — restarting engine")
        stopEngine()
        triedFallbacks.removeAll()
        do {
            try startEngine()
        } catch CaptureError.selectedDeviceMissing {
            // User-pinned device went away. Don't silently fall back — let
            // the lamp + UI reflect the disconnect.
            TrayLog.append("audio: pinned device gone after config change — staying disconnected")
            return
        } catch {
            // Default-device transient failure during a config event. Cycle
            // through alternatives instead of leaving the user stranded.
            TrayLog.append("audio: restart after config change failed (\(error.localizedDescription)) — trying alternatives")
            try? cycleToFirstWorkingDevice(initialError: error)
        }
        scheduleSilenceProbe(originalRequest: currentDeviceUID)
    }

    // MARK: - Lifecycle (main-thread only)

    /// Idempotent. Safe to call on every hotkey-press / session start.
    /// Brings the engine up if it isn't running, using the previously
    /// configured `currentDeviceUID` (set via `setSelectedDevice(_:)` at
    /// app launch or via `setDeviceUID(_:)` from the tray mic picker).
    func ensureRunning() throws {
        if engine.isRunning { return }
        try startEngine()
    }

    /// Public stop. Idempotent. Brings the engine down so the macOS green
    /// mic indicator disappears from the menubar between sessions.
    /// Safe to call on every session end.
    func stop() {
        guard engine.isRunning else { return }
        TrayLog.append("audio: stopping engine (on-demand mode)")
        stopEngine()
    }

    /// Store the user's preferred input device UID **without** starting the
    /// engine. Used at app launch in on-demand mode — the engine starts on
    /// first session and reads this UID then. Pass `nil` for system default.
    func setSelectedDevice(_ uid: String?) {
        let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentDeviceUID = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private var probeTask: Task<Void, Never>?

    /// UIDs the silence-probe has already tried during the current
    /// fallback chain. Cleared whenever the user makes a fresh selection.
    private var triedFallbacks: Set<String> = []

    /// True once `onAllMicsFailed` has fired and not been recovered yet.
    /// Drives the matched `onMicsRecovered` emit on next probe success.
    private var inTotalFailure = false

    func setDeviceUID(_ uid: String?) throws {
        probeTask?.cancel()
        probeTask = nil
        triedFallbacks.removeAll()
        let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentDeviceUID = (trimmed?.isEmpty == false) ? trimmed : nil
        if engine.isRunning { stopEngine() }
        do {
            try startEngine()
        } catch CaptureError.selectedDeviceMissing(let uid) {
            // Strict: a user-pinned UID that's currently absent must fail
            // loudly so the lamp goes to 'mic disconnected' and recording
            // refuses to silently capture from something else.
            throw CaptureError.selectedDeviceMissing(uid: uid)
        } catch {
            // Default-device failure (e.g. macOS made an aggregate device the
            // default and AVAudioEngine can't open it — coreaudio error 35).
            // Fall back through the candidate list until one starts.
            TrayLog.append("audio: startEngine failed (\(error.localizedDescription)) — trying alternatives")
            try cycleToFirstWorkingDevice(initialError: error)
        }
        // Always probe — even a freshly-started engine can be reading silence
        // (built-in mic muted via hardware key, broken driver, etc).
        scheduleSilenceProbe(originalRequest: currentDeviceUID)
    }

    /// Iterate `inputDevices()` and start the engine on the first candidate
    /// we haven't tried yet. Throws the original error if everything fails.
    private func cycleToFirstWorkingDevice(initialError: Error) throws {
        triedFallbacks.insert(currentDeviceUID ?? "")
        let candidates = AudioDevices.inputDevices()
        for dev in candidates where !triedFallbacks.contains(dev.uid) {
            triedFallbacks.insert(dev.uid)
            currentDeviceUID = dev.uid
            if engine.isRunning { stopEngine() }
            do {
                try startEngine()
                TrayLog.append("audio: started on fallback '\(dev.name)'")
                return
            } catch {
                TrayLog.append("audio: candidate '\(dev.name)' failed to start — \(error.localizedDescription)")
                continue
            }
        }
        // Nothing worked. Mark total failure so the UI knows.
        currentDeviceUID = nil
        if !inTotalFailure {
            inTotalFailure = true
            onAllMicsFailed?()
        }
        throw initialError
    }

    private func scheduleSilenceProbe(originalRequest: String?) {
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.evaluateProbeResult(originalRequest: originalRequest)
            }
        }
    }

    private func evaluateProbeResult(originalRequest: String?) {
        let snapshot = preRollSnapshot()
        // Need at least ~1s of buffer to make a confident call.
        guard snapshot.count >= 32000 else { return }
        let rms = snapshot.rmsInt16()
        if rms >= 10 {
            // Audio is flowing. If we'd previously declared total failure,
            // the bad state has cleared — recovery callback unblocks the UI.
            if inTotalFailure {
                inTotalFailure = false
                onMicsRecovered?()
            }
            return
        }

        // Silent — try the next candidate that we haven't already tried.
        triedFallbacks.insert(currentDeviceUID ?? "")
        let candidates = AudioDevices.inputDevices()
        for dev in candidates where !triedFallbacks.contains(dev.uid) {
            TrayLog.append("audio: probe — '\(currentDeviceUID ?? "default")' silent (RMS=\(String(format: "%.1f", rms))), trying '\(dev.name)'")
            triedFallbacks.insert(dev.uid)
            currentDeviceUID = dev.uid
            if engine.isRunning { stopEngine() }
            do {
                try startEngine()
                scheduleSilenceProbe(originalRequest: originalRequest)
                return
            } catch {
                TrayLog.append("audio: candidate '\(dev.name)' failed to start — \(error.localizedDescription)")
                continue
            }
        }

        // Exhausted all options — no working mic anywhere on this machine.
        TrayLog.append("audio: no working mic found after probing \(triedFallbacks.count) candidates")
        currentDeviceUID = nil
        if engine.isRunning { stopEngine() }
        if !inTotalFailure {
            inTotalFailure = true
            onAllMicsFailed?()
        }
    }

    private func startEngine() throws {
        // Strict mic selection: if the user pinned a specific device by UID
        // and that UID isn't currently present, refuse to start. We don't want
        // to silently fall back to the system default — Max would think his
        // DJI is recording while we're actually capturing the built-in mic.
        if let uid = currentDeviceUID {
            guard let dev = AudioDevices.device(uid: uid) else {
                isAvailable = false
                throw CaptureError.selectedDeviceMissing(uid: uid)
            }
            TrayLog.append("audio: setInputDevice -> \(dev.name) (uid=\(dev.uid))")
            try AudioDevices.setInputDevice(dev.id, on: engine)
        } else {
            let visible = AudioDevices.inputDevices().map { "\($0.name)" }.joined(separator: ", ")
            TrayLog.append("audio: using system default — visible devices: [\(visible)]")
        }

        let input = engine.inputNode

        // Apple AEC (`setVoiceProcessingEnabled(true)`) is intentionally NOT
        // enabled here. On this Mac it caused every mic candidate to report
        // sampleRate=0/channels=0 once VP was set on the input node — the
        // AudioCapture engine ended up in a broken state and `cycleToFirst-
        // WorkingDevice` exhausted all candidates with "No audio input
        // device available". Tracked for follow-up: AEC needs per-device-
        // type gating (built-in mic OK, aggregates fail) and probably a
        // dedicated engine instance for the meeting path. For now we ship
        // Phase 4 without AEC; on speakers the user may see Speaker N's
        // voice echoing into Speaker 1's channel — Deepgram's diarization
        // usually still attributes the bulk correctly.

        let inputFormat = input.inputFormat(forBus: 0)
        TrayLog.append("audio: inputFormat sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
        guard inputFormat.sampleRate > 0 else {
            isAvailable = false
            throw CaptureError.noInputDevice
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard converter != nil else {
            isAvailable = false
            throw CaptureError.formatUnsupported("converter init from \(inputFormat)")
        }

        lock.lock()
        pendingBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            isAvailable = false
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        isAvailable = true
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock()
        pendingBuffer.removeAll(keepingCapacity: false)
        ring.removeAll(keepingCapacity: false)
        lock.unlock()
        isAvailable = false
    }

    // MARK: - Subscriptions

    func subscribe(_ handler: @escaping (Data) -> Void) -> SubscriptionID {
        let id = UUID()
        lock.lock()
        subscribers[id] = handler
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: SubscriptionID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Snapshot of the last `preRollSeconds` of PCM. Empty until the engine has been running that long.
    func preRollSnapshot() -> Data {
        lock.lock()
        let snapshot = ring
        lock.unlock()
        return snapshot
    }

    // MARK: - Audio-thread processing

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)

        guard let out = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedFrames
        ) else { return }

        var error: NSError?
        var gave = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if gave {
                outStatus.pointee = .noDataNow
                return nil
            }
            gave = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            onError?(error)
            return
        }
        guard status != .error, out.frameLength > 0 else { return }
        guard let i16 = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * targetBytesPerFrame
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(i16[0]), count: byteCount)

        let chunkByteCount = Int(targetChunkFrames) * targetBytesPerFrame
        var extracted: [Data] = []
        var subs: [(Data) -> Void] = []

        lock.lock()
        pendingBuffer.append(contentsOf: bytes)
        while pendingBuffer.count >= chunkByteCount {
            let chunk = Data(pendingBuffer.prefix(chunkByteCount))
            pendingBuffer.removeFirst(chunkByteCount)
            extracted.append(chunk)
            ring.append(chunk)
        }
        if ring.count > ringMaxBytes {
            ring.removeFirst(ring.count - ringMaxBytes)
        }
        subs = Array(subscribers.values)
        lock.unlock()

        for chunk in extracted {
            for handler in subs { handler(chunk) }
        }
    }
}
