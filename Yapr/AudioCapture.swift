import AVFoundation
import AudioToolbox
import os

enum AudioCaptureError: LocalizedError {
    case deviceUnavailable, noInput
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "The selected audio device could not be opened."
        case .noInput: return "No microphone input is available."
        }
    }
}

/// Captures the microphone, hands out mono 16 kHz samples for Phonon-2 and an input level for the UI, and optionally
/// plays the microphone back on a chosen output device (pass-through). Capture and playback run on separate engines so
/// input and output can be different devices.
final class AudioCapture {
    /// DEBUG builds with YAPR_MIC_LOG=<file> set write capture events there.
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["YAPR_MIC_LOG"] else { return }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) \(message())\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
        #endif
    }
    private var buffers = 0
    /// Called on the audio tap thread.
    var onSamples: (([Float]) -> Void)?
    /// 0...1, called on the audio tap thread.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var monitor: PassThroughMonitor?
    private let monitorLock = OSAllocatedUnfairLock()
    private var configObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private var lastStart: (input: String, output: String, passThrough: Bool)?
    private var tapFormat: AVAudioFormat?
    private var recoveries: [Date] = []

    func start(inputUID: String, outputUID: String, passThrough: Bool) throws {
        teardown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AudioDevices.deviceID(forUID: inputUID) {
            try AudioCapture.setDevice(device, on: input)
        }
        let hwFormat = input.outputFormat(forBus: 0)
        AudioCapture.log("start input=\(inputUID.isEmpty ? "default" : inputUID) format=\(hwFormat)")
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { throw AudioCaptureError.noInput }

        installTap(on: input, format: hwFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        if passThrough { setPassThrough(true, outputUID: outputUID) }
        lastStart = (inputUID, outputUID, passThrough)

        recoveries = []
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in self?.configurationChanged() }
        // Long sessions: keep the Mac from idle-sleeping while it listens.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Yapr is transcribing")
        }
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: targetFormat)
        tapFormat = format
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    /// AVAudioEngine posts configuration changes freely: some USB, HDMI and virtual audio devices trigger one every
    /// few hundred milliseconds while nothing about the input changes. Tearing the engine down for each of those closes
    /// and reopens the microphone in a loop, and no audio ever arrives. So: while the engine still runs on the same
    /// format, carry on. If it really stopped, start the same engine again in place, re-tapping only when the format
    /// changed, and give up after a few tries rather than loop.
    private func configurationChanged() {
        guard let engine, let p = lastStart else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sameFormat = format.sampleRate == tapFormat?.sampleRate && format.channelCount == tapFormat?.channelCount
        AudioCapture.log("configuration change: running=\(engine.isRunning) sameFormat=\(sameFormat) format=\(format)")
        if engine.isRunning && sameFormat { return }

        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard recoveries.count <= 3 else {
            AudioCapture.log("configuration change: too many recoveries, rebuilding once on the default input")
            let keepActivity = activity
            activity = nil
            teardown()
            activity = keepActivity
            try? start(inputUID: "", outputUID: p.output, passThrough: p.passThrough)
            return
        }
        if !sameFormat {
            guard format.sampleRate > 0, format.channelCount > 0 else { return }   // device gone; wait for the next change
            input.removeTap(onBus: 0)
            installTap(on: input, format: format)
        }
        engine.prepare()
        do { try engine.start(); AudioCapture.log("configuration change: restarted in place") }
        catch { AudioCapture.log("configuration change: restart failed: \(error.localizedDescription)") }
    }

    func stop() {
        AudioCapture.log("stop after \(buffers) buffers")
        teardown()
        lastStart = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        setPassThrough(false, outputUID: "")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func setPassThrough(_ on: Bool, outputUID: String) {
        monitorLock.withLockUnchecked {
            monitor?.stop()
            monitor = nil
        }
        guard on, let mono = monoFormat, engine != nil else { return }
        let m = PassThroughMonitor(format: mono)
        do {
            try m.start(outputUID: outputUID)
            monitorLock.withLockUnchecked { monitor = m }
        } catch {
            NSLog("Yapr: pass-through unavailable: \(error.localizedDescription)")
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        if buffers % 100 == 1 { AudioCapture.log("buffer \(buffers) frames=\(buffer.frameLength)") }
        guard let mono = downmix(buffer) else { return }
        let samples = UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))

        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(1, samples.count))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        onLevel?(min(1, max(0, (db + 55) / 45)))

        monitorLock.withLockUnchecked { monitor?.push(samples) }

        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * targetFormat.sampleRate / mono.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        if error == nil, out.frameLength > 0 {
            onSamples?(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
        }
    }

    /// Mono at the hardware rate: the average of a stereo pair, or the first channel of a multi-channel interface.
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat, let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        let dst = out.floatChannelData![0]
        if channels == 2 {
            for i in 0..<n { dst[i] = 0.5 * (src[0][i] + src[1][i]) }
        } else {
            dst.update(from: src[0], count: n)
        }
        out.frameLength = buffer.frameLength
        return out
    }

    static func setDevice(_ device: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw AudioCaptureError.deviceUnavailable }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw AudioCaptureError.deviceUnavailable }
    }
}

/// Plays mono microphone samples on an output device through a small ring buffer (latency capped at ~120 ms).
final class PassThroughMonitor {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let ring: RingBuffer

    init(format: AVAudioFormat) {
        self.format = format
        ring = RingBuffer(capacity: Int(format.sampleRate))   // 1 s of headroom
    }

    func start(outputUID: String) throws {
        let output = engine.outputNode
        if let device = AudioDevices.deviceID(forUID: outputUID) {
            try AudioCapture.setDevice(device, on: output)
        }
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(into: data, count: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func push(_ samples: UnsafeBufferPointer<Float>) {
        ring.write(samples, maxFill: Int(format.sampleRate * 0.12))
    }

    func stop() { engine.stop() }
}

final class RingBuffer {
    private var storage: [Float]
    private var readIndex = 0, count = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }

    func write(_ samples: UnsafeBufferPointer<Float>, maxFill: Int) {
        lock.withLockUnchecked {
            let cap = storage.count
            for s in samples {
                storage[(readIndex + count) % cap] = s
                if count < cap { count += 1 } else { readIndex = (readIndex + 1) % cap }
            }
            if count > maxFill {               // drop the oldest audio to keep latency low
                let drop = count - maxFill
                readIndex = (readIndex + drop) % cap
                count = maxFill
            }
        }
    }

    func read(into dst: UnsafeMutablePointer<Float>, count n: Int) {
        lock.withLockUnchecked {
            let cap = storage.count
            let available = min(n, count)
            for i in 0..<available { dst[i] = storage[(readIndex + i) % cap] }
            for i in available..<n { dst[i] = 0 }
            readIndex = (readIndex + available) % cap
            count -= available
        }
    }
}
