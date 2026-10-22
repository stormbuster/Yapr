import AVFoundation
import AppKit
import Combine
import PhononCoreML

struct DisplayWord: Identifiable, Equatable {
    let id: Int
    var text: String
    var final: Bool
}

/// The app's state: model download and load, recording, and the words shown in the circle.
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case downloading(Double)
        case preparing(String)
        case ready
        case recording
        case finishing
        case transcribingFile(name: String, progress: Double)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing("Waking up")
    @Published private(set) var words: [DisplayWord] = []
    @Published private(set) var level: Float = 0

    /// Called with the full transcript and its file when a recording stops.
    var onTranscript: ((String, URL?) -> Void)?

    private let settings = Settings.shared
    private let capture = AudioCapture()
    private var transcriber: Transcriber?
    private var live: LiveTranscriber?
    private var fileQueue: [URL] = []
    private var fileJob: FileTranscriber?
    private var revealBacklog: [String] = []
    private var revealTimer: Timer?
    private var file: TranscriptFile?
    private var committed: [DisplayWord] = []
    private var hypothesis: [DisplayWord] = []
    private var nextID = 0
    private var cancellables: Set<AnyCancellable> = []
    private static let visibleWords = 28

    init() {
        settings.$passThrough.dropFirst().sink { [weak self] on in
            guard let self, self.phase == .recording else { return }
            self.capture.setPassThrough(on, outputUID: self.settings.outputDeviceUID)
        }.store(in: &cancellables)
        settings.$outputDeviceUID.dropFirst().sink { [weak self] uid in
            guard let self, self.phase == .recording, self.settings.passThrough else { return }
            self.capture.setPassThrough(true, outputUID: uid)
        }.store(in: &cancellables)

        capture.onLevel = { [weak self] value in
            DispatchQueue.main.async { self?.level = value }
        }
        capture.onSamples = { [weak self] samples in self?.live?.append(samples) }
        capture.onFailure = { [weak self] message in
            guard let self, self.phase == .recording else { return }
            self.stop(failure: message)
        }
    }

    // MARK: model

    func loadModel() {
        let store = ModelStore.shared
        if store.isInstalled { prepare(store.directory); return }
        phase = .downloading(0)
        store.download(progress: { [weak self] p in
            if case .downloading = self?.phase { self?.phase = .downloading(p) }
        }, completion: { [weak self] error in
            if let error { self?.phase = .failed(error.localizedDescription) } else { self?.prepare(store.directory) }
        })
    }

    private func prepare(_ bundle: URL) {
        phase = .preparing("Loading Phonon 2")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var options = Transcriber.Options()
            options.singleShotMaxSeconds = 15
            options.eagerFunctions = [15]
            #if arch(x86_64)
            // Intel Macs have no Neural Engine, so Phonon runs on the CPU, where every encoder size holds its own
            // unpacked copy of the weights. One size (15 s) serves both live phrases and file chunks.
            options.computeUnits = .cpuOnly
            options.functions = [15]
            options.encoderInFlight = 1        // concurrent CPU predictions only add memory, not speed
            options.decoderWorkers = 2
            #else
            options.functions = [5, 10, 15]
            options.backgroundLoad = true
            #endif
            // The first load on a Mac prepares the model for the Neural Engine (a minute or two, once); say so only if it is slow.
            options.progress = { stage, _ in
                guard stage == "compiling" || stage.hasPrefix("loading enc_15") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if self?.phase == .preparing("Loading Phonon 2") {
                        self?.phase = .preparing("Tuning Phonon 2 for this Mac.\nOnce only, a minute or two.")
                    }
                }
            }
            do {
                let transcriber = try Transcriber(bundle: bundle, options: options)
                _ = try? transcriber.transcribe((0..<16_000).map { i in 0.01 * sin(Float(i) * 0.05) })   // warm up
                DispatchQueue.main.async {
                    self?.transcriber = transcriber
                    self?.live = LiveTranscriber(transcriber: transcriber)
                    self?.becomeReady()
                }
            } catch {
                DispatchQueue.main.async { self?.phase = .failed("Phonon 2 did not load: \(error.localizedDescription)") }
            }
        }
    }

    func retry() {
        if live == nil { loadModel() } else { becomeReady() }
    }

    private func becomeReady() {
        phase = .ready
        transcribeNextFile()
    }

    // MARK: recording

    func toggleRecording() {
        switch phase {
        case .ready: requestMicrophoneThenStart()
        case .recording: stop()
        default: break
        }
    }

    private func requestMicrophoneThenStart() {
        AudioCapture.log("microphone authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.start() : self.microphoneDenied() }
            }
        default: microphoneDenied()
        }
    }

    private func microphoneDenied() {
        phase = .failed("Yapr needs the microphone.\nAllow it in System Settings › Privacy & Security › Microphone.")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func start(feed: [Float]? = nil) {
        guard let live else { return }
        do {
            let file = try TranscriptFile(folder: settings.transcriptsFolder)
            self.file = file
            committed = []; hypothesis = []; words = []
            live.onCommit = { [weak file] text in file?.append(text) }
            live.onUpdate = { [weak self] newlyCommitted, liveWords in self?.apply(committed: newlyCommitted, live: liveWords) }
            live.begin()
            if let feed {
                #if DEBUG
                feedInRealTime(feed)
                #endif
            } else {
                settings.reconnectDevices()
                try capture.start(inputUID: settings.inputDeviceUID, outputUID: settings.outputDeviceUID, passThrough: settings.passThrough)
            }
            phase = .recording
        } catch {
            live.finish {}
            file?.close(); file = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops recording, commits what is still live, saves and shows the transcript. With `failure`, the circle then
    /// shows that message (and Try again) instead of returning to the microphone.
    private func stop(failure: String? = nil) {
        phase = .finishing
        capture.stop()
        level = 0
        var finished = false
        let finish = { [weak self] in
            guard let self, !finished else { return }
            finished = true
            let file = self.file
            file?.close()
            self.file = nil
            self.committed = []; self.hypothesis = []; self.words = []
            let text = file?.text ?? ""
            if !text.isEmpty || failure == nil { self.onTranscript?(text, text.isEmpty ? nil : file?.url) }
            if let failure { self.phase = .failed(failure) } else { self.becomeReady() }
        }
        live?.finish(finish)
        // Never leave the button stuck: if the last pass has not come back in 20 s, finish with what is saved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if !finished { AudioCapture.log("stop: final pass timed out"); finish() } }
    }

    // MARK: audio and video files

    /// Queues dropped or opened files; they are transcribed one after another whenever Yapr is not recording.
    /// Returns false when none of them is an audio or video file.
    @discardableResult
    func transcribeFiles(_ urls: [URL]) -> Bool {
        let media = urls.filter(MediaDecoder.canRead)
        guard !media.isEmpty else {
            if phase == .ready { phase = .failed("Yapr transcribes audio and video files.") }
            return false
        }
        fileQueue.append(contentsOf: media)
        if phase == .ready { transcribeNextFile() }
        return true
    }

    private func transcribeNextFile() {
        guard phase == .ready, let transcriber, !fileQueue.isEmpty else { return }
        let url = fileQueue.removeFirst()
        let name = url.deletingPathExtension().lastPathComponent
        let file: TranscriptFile
        do { file = try TranscriptFile(folder: settings.transcriptsFolder, baseName: name) } catch {
            phase = .failed(error.localizedDescription); return
        }
        let job = FileTranscriber(transcriber: transcriber)
        fileJob = job
        committed = []; hypothesis = []; words = []; revealBacklog = []
        phase = .transcribingFile(name: name, progress: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            var failure: Error?
            do {
                try job.run(url,
                            onText: { text in DispatchQueue.main.async { file.append(text) } },
                            onWords: { words in DispatchQueue.main.async { self?.reveal(words) } },
                            onProgress: { p in
                                DispatchQueue.main.async {
                                    if case .transcribingFile(name, let old) = self?.phase, p - old >= 0.005 || p == 1 {
                                        self?.phase = .transcribingFile(name: name, progress: p)
                                    }
                                }
                            })
            } catch is FileTranscriber.Cancelled {
            } catch { failure = error }
            DispatchQueue.main.async { self?.finishFile(file, failure: failure) }
        }
    }

    /// Stops the file being transcribed; what was recognised so far is kept and shown.
    func cancelFile() { fileJob?.cancel() }

    private func finishFile(_ file: TranscriptFile, failure: Error?) {
        fileJob = nil
        // Let the last words drift in before the page opens.
        let wait = min(1.2, 0.35 + Double(revealBacklog.count) * 0.075)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.revealTimer?.invalidate(); self.revealTimer = nil; self.revealBacklog = []
            self.committed = []; self.hypothesis = []; self.words = []
            file.close()
            if let failure, file.text.isEmpty { self.phase = .failed(failure.localizedDescription); return }
            self.onTranscript?(file.text, file.text.isEmpty ? nil : file.url)
            self.becomeReady()
        }
    }

    /// Phonon 2 recognises half a minute of a file in a blink, so words are paced into the circle one at a time, as in
    /// live speech. When recognition races ahead, older waiting words are skipped so the circle stays near the
    /// current position in the file.
    private func reveal(_ newWords: [String]) {
        revealBacklog.append(contentsOf: newWords)
        guard revealTimer == nil else { return }
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { [weak self] timer in
            guard let self, !self.revealBacklog.isEmpty else { timer.invalidate(); self?.revealTimer = nil; return }
            if self.revealBacklog.count > 24 {
                self.revealBacklog.removeFirst(self.revealBacklog.count - 24)
                self.committed = []          // a jump: start the circle afresh rather than splice unrelated text
            }
            self.committed.append(DisplayWord(id: self.makeID(), text: self.revealBacklog.removeFirst(), final: true))
            if self.committed.count > AppModel.visibleWords { self.committed.removeFirst(self.committed.count - AppModel.visibleWords) }
            self.words = self.committed
        }
    }

    // MARK: words in the circle

    /// Committed words keep the ids they had as hypothesis words, and a hypothesis word keeps its id while its position is
    /// unchanged, so only genuinely new words animate in.
    private func apply(committed newlyCommitted: [String], live liveWords: [String]) {
        if !newlyCommitted.isEmpty {
            for (i, text) in newlyCommitted.enumerated() {
                let id = i < hypothesis.count ? hypothesis[i].id : makeID()
                committed.append(DisplayWord(id: id, text: text, final: true))
            }
            hypothesis = Array(hypothesis.dropFirst(newlyCommitted.count))
            if committed.count > AppModel.visibleWords { committed.removeFirst(committed.count - AppModel.visibleWords) }
        }
        hypothesis = liveWords.enumerated().map { i, text in
            DisplayWord(id: i < hypothesis.count ? hypothesis[i].id : makeID(), text: text, final: false)
        }
        words = Array((committed + hypothesis).suffix(AppModel.visibleWords))
    }

    private func makeID() -> Int { nextID += 1; return nextID }

    #if DEBUG
    func debugDoubleTap() -> String { capture.debugDoubleTap() }

    /// Test hook: records from 16 kHz mono samples instead of the microphone, paced like a live speaker.
    func debugStart(feeding samples: [Float]) { start(feed: samples) }

    private func feedInRealTime(_ samples: [Float]) {
        var offset = 0
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.phase == .recording, offset < samples.count else { timer.invalidate(); return }
            let due = min(samples.count, Int(Date().timeIntervalSince(t0) * 16_000))
            guard due > offset else { return }
            let chunk = Array(samples[offset..<due])
            offset = due
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            self.level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 55) / 45))
            self.live?.append(chunk)
        }
    }
    #endif
}
