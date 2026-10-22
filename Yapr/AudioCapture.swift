import AVFoundation
import AudioToolbox
import os

enum AudioCaptureError: LocalizedError {
    case deviceUnavailable, noInput, engine(String)
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "The selected audio device could not be opened."
        case .noInput: return "No microphone input is available."
        case .engine(let reason): return "The microphone could not be opened (\(reason))."
        }
    }
}

/// Runs AVAudioEngine work that may raise an Objective-C exception, as a Swift error instead.
private func objc(_ block: () -> Void) throws {
    if let error = YaprCatchException(block) {
        AudioCapture.log("exception: \(error.localizedDescription)")
        throw AudioCaptureError.engine(error.localizedDescription)
    }
}

/// Captures the microphone, hands out mono 16 kHz samples for Phonon-2 and an input level for the UI, and optionally
/// plays the microphone back on a chosen output device (pass-through). Capture and playback run on separate engines so
/// input and output can be different devices.
///
/// Devices come and go (USB hubs reset, cameras sleep, HDMI renegotiates), so capture is defensive: the tap takes
/// whatever format the hardware delivers and adapts to it, AVAudioEngine's exceptions become errors, and a watchdog
/// rebuilds capture when no audio has arrived for a few seconds, then gives up with a message instead of hanging.
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

    /// Called on the audio tap thread.
    var onSamples: (([Float]) -> Void)?
    /// 0...1, called on the audio tap thread.
    var onLevel: ((Float) -> Void)?
    /// Main queue: capture failed and could not be recovered; recording should stop with this message.
    var onFailure: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var monitor: PassThroughMonitor?
    private let monitorLock = OSAllocatedUnfairLock()
    private var configObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private var lastStart: (input: String, output: String, passThrough: Bool)?
    private var watchdog: Timer?
    private var startedAt = Date()
    private var rebuilds = 0
    private var recoveries: [Date] = []

    // Shared with the tap thread, under `state`.
    private let state = OSAllocatedUnfairLock()
    private var sourceFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var lastBufferAt = Date.distantPast
    private var buffers = 0

    private static let silenceLimit: TimeInterval = 3   // seconds without a buffer before capture counts as dead

    func start(inputUID: String, outputUID: String, passThrough: Bool) throws {
        try open(inputUID: inputUID, outputUID: outputUID, passThrough: passThrough)
        rebuilds = 0
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkHealth() }
        // Long sessions: keep the Mac from idle-sleeping while it listens.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Yapr is transcribing")
        }
    }

    /// Builds a fresh engine on the chosen input (or the system default) and starts it.
    private func open(inputUID: String, outputUID: String, passThrough: Bool) throws {
        teardown()
        let engine = AVAudioEngine()
        var maybeInput: AVAudioInputNode?
        try objc { maybeInput = engine.inputNode }
        guard let input = maybeInput else { throw AudioCaptureError.noInput }
        if let device = AudioDevices.deviceID(forUID: inputUID) {
            try AudioCapture.setDevice(device, on: input)
        }
        let format = input.outputFormat(forBus: 0)
        AudioCapture.log("open input=\(inputUID.isEmpty ? "default" : inputUID) format=\(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInput }

        state.withLockUnchecked { sourceFormat = nil; lastBufferAt = .distantPast; buffers = 0 }
        try installTap(on: input)
        var startError: Error?
        try objc {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        self.engine = engine
        startedAt = Date()
        lastStart = (inputUID, outputUID, passThrough)
        recoveries = []
        if passThrough { setPassThrough(true, outputUID: outputUID) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in self?.configurationChanged() }
    }

    /// The tap takes the node's own format (format: nil), so it can never mismatch the hardware; `process` adapts
    /// to whatever arrives.
    private func installTap(on input: AVAudioInputNode) throws {
        try objc {
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in self?.process(buffer) }
        }
    }

    /// AVAudioEngine posts configuration changes freely: some USB, HDMI and virtual audio devices trigger one every
    /// few hundred milliseconds while nothing about the input changes. While the engine still runs, carry on; the
    /// tap adapts to a new format by itself. If it stopped, start it again in place (a few times at most); the
    /// watchdog takes over if audio still does not come.
    private func configurationChanged() {
        guard let engine, lastStart != nil else { return }
        AudioCapture.log("configuration change: running=\(engine.isRunning)")
        if engine.isRunning { return }
        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard recoveries.count <= 3 else { return }
        do {
            try objc { engine.inputNode.removeTap(onBus: 0) }
            try installTap(on: engine.inputNode)
            var startError: Error?
            try objc {
                engine.prepare()
                do { try engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
            AudioCapture.log("configuration change: restarted in place")
        } catch {
            AudioCapture.log("configuration change: restart failed: \(error.localizedDescription)")
        }
    }

    /// Once a second while recording: if no audio has arrived for a while, rebuild capture from scratch (on the
    /// chosen input, then the system default); if that does not help either, stop and say so.
    private func checkHealth() {
        guard let p = lastStart else { return }
        let now = Date()
        let last = state.withLockUnchecked { lastBufferAt }
        // Only real audio since the last (re)open counts as recovery; opening the engine again does not.
        if last > startedAt && now.timeIntervalSince(last) < AudioCapture.silenceLimit { rebuilds = 0; return }
        let silent = now.timeIntervalSince(max(last, startedAt))
        guard silent >= AudioCapture.silenceLimit else { return }
        rebuilds += 1
        AudioCapture.log("watchdog: no audio for \(String(format: "%.1f", silent)) s, rebuild \(rebuilds)")
        if rebuilds <= 2 {
            do { try open(inputUID: rebuilds == 1 ? p.input : "", outputUID: p.output, passThrough: p.passThrough); return }
            catch { AudioCapture.log("watchdog: rebuild failed: \(error.localizedDescription)") }
            if rebuilds < 2 { return }
        }
        stop()
        onFailure?("No sound is arriving from the microphone.\nCheck it is connected, then try again.")
    }

    func stop() {
        AudioCapture.log("stop after \(state.withLockUnchecked { buffers }) buffers")
        watchdog?.invalidate()
        watchdog = nil
        teardown()
        lastStart = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        setPassThrough(false, outputUID: "")
        if let engine {
            try? objc {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        engine = nil
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func setPassThrough(_ on: Bool, outputUID: String) {
        monitorLock.withLockUnchecked {
            monitor?.stop()
            monitor = nil
        }
        let mono = state.withLockUnchecked { monoFormat }
            ?? engine.flatMap { e in
                let f = e.inputNode.outputFormat(forBus: 0)
                return f.sampleRate > 0 ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate, channels: 1, interleaved: false) : nil
            }
        guard on, let mono, engine != nil else { return }
        let m = PassThroughMonitor(format: mono)
        do {
            try m.start(outputUID: outputUID)
            monitorLock.withLockUnchecked { monitor = m }
        } catch {
            NSLog("Yapr: pass-through unavailable: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    private let debugStall = ProcessInfo.processInfo.environment["YAPR_MIC_STALL"] != nil
    /// Test hook: tapping the same input twice makes AVAudioEngine raise an exception; it must come back as an error.
    func debugDoubleTap() -> String {
        guard let engine else { return "no engine" }
        do { try installTap(on: engine.inputNode); return "no exception (unexpected)" }
        catch { return "caught: \(error.localizedDescription)" }
    }
    #endif

    private func process(_ buffer: AVAudioPCMBuffer) {
        #if DEBUG
        if debugStall { return }   // test hook: behave like a microphone that delivers nothing
        #endif
        // Adapt to the format the hardware delivers; it can change when a device reconnects.
        let (mono, converter, formatChanged): (AVAudioFormat?, AVAudioConverter?, Bool) = state.withLockUnchecked {
            lastBufferAt = Date()
            buffers += 1
            if buffers % 100 == 1 { AudioCapture.log("buffer \(buffers) frames=\(buffer.frameLength) format=\(buffer.format)") }
            var changed = false
            if sourceFormat == nil || sourceFormat! != buffer.format {
                changed = sourceFormat != nil
                sourceFormat = buffer.format
                monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)
                self.converter = monoFormat.flatMap { AVAudioConverter(from: $0, to: targetFormat) }
            }
            return (monoFormat, self.converter, changed)
        }
        if formatChanged, let p = lastStart, p.passThrough {
            DispatchQueue.main.async { [weak self] in self?.setPassThrough(true, outputUID: p.output) }
        }
        guard let monoFormat = mono, let monoBuffer = downmix(buffer, to: monoFormat) else { return }
        let samples = UnsafeBufferPointer(start: monoBuffer.floatChannelData![0], count: Int(monoBuffer.frameLength))

        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(1, samples.count))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        onLevel?(min(1, max(0, (db + 55) / 45)))

        monitorLock.withLockUnchecked { monitor?.push(samples) }

        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(monoBuffer.frameLength) * targetFormat.sampleRate / monoFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return monoBuffer
        }
        if error == nil, out.frameLength > 0 {
            onSamples?(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
        }
    }

    /// Mono at the hardware rate: the average of a stereo pair, or the first channel of a multi-channel interface.
    private func downmix(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, buffer.frameLength > 0,
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
