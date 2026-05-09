import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures system audio output via ScreenCaptureKit and converts it to
/// 16 kHz mono Int16 PCM. Used by `MeetingSession` to merge a second channel
/// (other participants on calls) alongside the user's mic.
///
/// First-run UX: when `start()` is called for the first time, macOS prompts
/// the user to grant Screen Recording permission. Subsequent starts are
/// silent.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject {

    /// Fires per chunk of converted PCM (16 kHz mono Int16). Called on the
    /// SCStream delegate's serial queue — NOT main.
    var onAudioChunk: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private let outputQueue = DispatchQueue(label: "voicemax.systemaudio.output")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var pendingBytes = Data()

    private let targetSampleRate: Double = 16000
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
    }()

    enum CaptureError: LocalizedError {
        case noContent
        case permissionDenied(String)
        case formatBuild(String)
        case streamStart(String)

        var errorDescription: String? {
            switch self {
            case .noContent:               return "No screen content available for system-audio capture"
            case .permissionDenied(let s): return "Screen Recording permission required: \(s)"
            case .formatBuild(let s):      return "Failed to build audio format: \(s)"
            case .streamStart(let s):      return "Failed to start system-audio stream: \(s)"
            }
        }
    }

    func start() async throws {
        // SCShareableContent triggers the permission prompt the first time.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noContent
        }

        // Filter selects what to capture. Audio doesn't actually depend on
        // the visual filter — we just need a valid SCContentFilter.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = Int(targetSampleRate)
        cfg.channelCount = 1
        // We don't actually display any captured frames — just make the
        // smallest possible video buffer so the SCStream is happy.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        } catch {
            throw CaptureError.streamStart("addStreamOutput: \(error.localizedDescription)")
        }
        do {
            try await s.startCapture()
        } catch {
            throw CaptureError.streamStart(error.localizedDescription)
        }
        self.stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
        converter = nil
        pendingBytes.removeAll()
    }
}

@available(macOS 13.0, *)
extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

@available(macOS 13.0, *)
extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = basicDesc.pointee
        let inputFormat = AVAudioFormat(streamDescription: basicDesc)!
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let conv = converter else { return }

        // Pull raw audio from the CMSampleBuffer into an AVAudioPCMBuffer.
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return
        }
        inputBuf.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: asbd.mChannelsPerFrame,
                mDataByteSize: 0,
                mData: nil
            )
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let srcData = audioBufferList.mBuffers.mData else { return }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        if let dst = inputBuf.mutableAudioBufferList.pointee.mBuffers.mData {
            memcpy(dst, srcData, byteCount)
        }

        // Convert to 16 kHz mono Int16. Output capacity sized for the rate ratio.
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var convError: NSError?
        var consumed = false
        let convStatus = conv.convert(to: outBuf, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuf
        }
        if let convError {
            onError?(convError)
            return
        }
        guard convStatus != .error, outBuf.frameLength > 0 else { return }
        guard let i16 = outBuf.int16ChannelData else { return }

        let outBytes = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(i16[0]), count: outBytes)
        pendingBytes.append(contentsOf: raw)

        // Emit in 320-frame (20 ms) chunks to match AudioCapture's cadence.
        let chunkBytes = 320 * MemoryLayout<Int16>.size
        while pendingBytes.count >= chunkBytes {
            let chunk = Data(pendingBytes.prefix(chunkBytes))
            pendingBytes.removeFirst(chunkBytes)
            onAudioChunk?(chunk)
        }
    }
}
