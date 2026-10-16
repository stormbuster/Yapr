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
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing("Waking up")
    @Published private(set) var words: [DisplayWord] = []
    @Published private(set) var level: Float = 0

    /// Called with the full transcript and its file when a recording stops.
    var onTranscript: ((String, URL?) -> Void)?

    private let settings = Settings.shared
    private let capture = AudioCapture()
    private var live: LiveTranscriber?
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
            options.functions = [5, 10, 15]
            options.singleShotMaxSeconds = 15
            options.eagerFunctions = [15]
            options.backgroundLoad = true
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
                    self?.live = LiveTranscriber(transcriber: transcriber)
                    self?.phase = .ready
                }
            } catch {
                DispatchQueue.main.async { self?.phase = .failed("Phonon 2 did not load: \(error.localizedDescription)") }
            }
        }
    }

    func retry() {
        if live == nil { loadModel() } else { phase = .ready }
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
                try capture.start(inputUID: settings.inputDeviceUID, outputUID: settings.outputDeviceUID, passThrough: settings.passThrough)
            }
            phase = .recording
        } catch {
            live.finish {}
            file?.close(); file = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        phase = .finishing
        capture.stop()
        level = 0
        live?.finish { [weak self] in
            guard let self else { return }
            let file = self.file
            file?.close()
            self.file = nil
            self.committed = []; self.hypothesis = []; self.words = []
            self.phase = .ready
            let text = file?.text ?? ""
            self.onTranscript?(text, text.isEmpty ? nil : file?.url)
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
