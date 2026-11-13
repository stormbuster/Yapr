import AVFoundation
import CoreAudio
import os

enum SystemAudioError: LocalizedError {
    case tap(OSStatus), aggregate(OSStatus), format, start(OSStatus)
    var errorDescription: String? {
        switch self {
        case .tap(let s): return "System audio could not be captured (tap \(s))."
        case .aggregate(let s): return "System audio could not be captured (device \(s))."
        case .format: return "System audio arrived in a format Yapr cannot read."
        case .start(let s): return "System audio could not be started (\(s))."
        }
    }
}

/// Everything the Mac plays, through a Core Audio process tap (macOS 14.2+): a global stereo tap is added to a private
/// aggregate device clocked by the current output device, and an IO proc hands its buffers out. Nothing is muted; the
/// sound still plays as usual. macOS asks once for System Audio Recording permission; until it is given, the tap
/// delivers silence.
final class SystemAudioTap {
    /// Called on the tap's IO queue.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Main queue: the default output device changed, so the tap should be rebuilt on the new one.
    var onOutputChange: (() -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.stormbuster.yapr.system-audio", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Yapr"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw SystemAudioError.tap(status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { stop(); throw SystemAudioError.format }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Yapr system audio",
            kAudioAggregateDeviceUIDKey: "com.stormbuster.yapr.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]],
        ]
        if let output = AudioDevices.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw SystemAudioError.aggregate(status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            self.onBuffer?(buffer)
        }
        guard status == noErr else { stop(); throw SystemAudioError.start(status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw SystemAudioError.start(status) }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onOutputChange?() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, listener)
        outputListener = listener
        AudioCapture.log("system audio: tap=\(tapID) aggregate=\(aggregateID) format=\(format)")
    }

    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, outputListener)
        }
        outputListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
