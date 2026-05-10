import AVFoundation
import CoreAudio
import Foundation

/// CoreAudio helpers: enumerate input-capable devices and apply one to an
/// `AVAudioEngine.inputNode`. We identify devices by their stable `deviceUID`
/// (same string survives reconnects / reboots) rather than the runtime
/// `AudioDeviceID`.
enum AudioDevices {

    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    // MARK: - Enumerate

    /// Returns every device that AVFoundation reports as currently present
    /// AND has a non-zero nominal sample rate (ghost CoreAudio entries often
    /// keep their UID and channel count but the sample rate falls to 0 once
    /// the physical device is gone).
    static func inputDevices() -> [Device] {
        let presentUIDs = Set(presentAudioCaptureDeviceUIDs())
        let ids = allDeviceIDs()
        return ids.compactMap { id in
            guard inputChannelCount(for: id) > 0 else { return nil }
            guard nominalSampleRate(for: id) > 0 else { return nil }
            guard let uid = string(for: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            guard presentUIDs.contains(uid) else { return nil }
            let name = string(for: id, selector: kAudioObjectPropertyName) ?? uid
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// AVFoundation discovery — authoritative list of currently-present audio
    /// capture devices by their CoreAudio-compatible `uniqueID`.
    ///
    /// `AVCaptureDevice.devices(for:)` is deprecated since macOS 10.15 in
    /// favour of `DiscoverySession`, but the only audio-input DeviceType
    /// (`.microphone`, `.external`) that covers external USB/BT mics is
    /// macOS 14+ and isn't always in the SDK we build against. The
    /// deprecated call is still fully functional on every macOS version
    /// and returns exactly the live audio device set we want.
    private static func presentAudioCaptureDeviceUIDs() -> [String] {
        AVCaptureDevice.devices(for: .audio).map { $0.uniqueID }
    }

    static func defaultInputDevice() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        guard status == noErr, id != 0 else { return nil }
        guard let uid = string(for: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(for: id, selector: kAudioObjectPropertyName) ?? uid
        return Device(id: id, uid: uid, name: name)
    }

    /// Lookup by persistent UID — returns nil if the device is currently unplugged.
    static func device(uid: String) -> Device? {
        inputDevices().first { $0.uid == uid }
    }

    // MARK: - Apply

    /// Point `AVAudioEngine.inputNode`'s underlying AUHAL at a specific device.
    /// Must be called **before** `engine.prepare()` / `engine.start()`.
    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "AudioDevices", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "inputNode has no audio unit"
            ])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: "AudioDevices", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioUnitSetProperty(CurrentDevice) failed: \(status)"
            ])
        }
    }

    // MARK: - Private: CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private static func nominalSampleRate(for device: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }

    private static func inputChannelCount(for device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, buf) == noErr else {
            return 0
        }
        let list = buf.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(for device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
            }
        }
        guard status == noErr, let str = cfString else { return nil }
        return str as String
    }
}
