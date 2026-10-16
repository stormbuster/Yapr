import Foundation
import PhononCoreML

/// Near-realtime transcription on top of Phonon-2's whole-buffer API.
///
/// Audio since the last commit is the "live segment". A few times a second the live segment is transcribed again (Phonon-2
/// runs hundreds of times faster than realtime on the Neural Engine, so this costs a few milliseconds); the result is shown as
/// a hypothesis. When the speaker pauses, or the segment grows past ~12 s, the words are committed: they never change again,
/// get appended to the transcript file, and the live segment starts over after them.
final class LiveTranscriber {
    /// Main queue: words committed by this pass, then the current hypothesis for the rest of the live segment.
    var onUpdate: ((_ committed: [String], _ live: [String]) -> Void)?
    /// Main queue: committed text, including its leading separator (a space or a paragraph break).
    var onCommit: ((String) -> Void)?

    private let transcriber: Transcriber
    private let queue = DispatchQueue(label: "yapr.asr", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Float] = []          // 16 kHz mono audio since the last commit
    private var timer: DispatchSourceTimer?
    private var hasText = false
    private var silenceCarried = 0.0          // trailing silence of the last committed segment, seconds

    private static let rate = 16_000.0
    #if arch(x86_64)
    // Intel: no Neural Engine, so each pass costs more; pass less often over shorter phrases.
    private static let tick = 0.5              // seconds between passes
    private static let maxSegment = 8.0        // force a commit, keeping each pass short
    #else
    private static let tick = 0.3              // seconds between passes
    private static let maxSegment = 12.0       // force a commit before Phonon needs its long-audio path
    #endif
    private static let pauseToCommit = 0.7     // seconds of trailing silence that end a phrase
    private static let keepLive = 2.0          // on a forced commit, the last seconds stay live
    private static let paragraphPause = 3.5    // silence that starts a new paragraph

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func begin() {
        lock.lock(); pending.removeAll(keepingCapacity: true); lock.unlock()
        hasText = false
        silenceCarried = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + LiveTranscriber.tick, repeating: LiveTranscriber.tick, leeway: .milliseconds(30))
        t.setEventHandler { [weak self] in self?.pass(final: false) }
        timer = t
        t.resume()
    }

    /// Any thread.
    func append(_ samples: [Float]) {
        lock.lock(); pending.append(contentsOf: samples); lock.unlock()
    }

    /// Commits whatever is still live, then calls back on the main queue.
    func finish(_ completion: @escaping () -> Void) {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            self?.pass(final: true)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func pass(final: Bool) {
        lock.lock(); let segment = pending; lock.unlock()
        let duration = Double(segment.count) / LiveTranscriber.rate
        guard duration >= (final ? 0.25 : 0.5) else {
            if final { trim(segment.count) }
            return
        }

        let energy = LiveTranscriber.energy(segment)
        guard energy.hasSpeech else {
            // Nothing but room noise: let go of it so the live segment does not grow without bound.
            if final || duration > 4 { trim(segment.count); silenceCarried += duration }
            publish(committed: [], live: [])
            return
        }

        let words: [Word]
        do { words = try transcriber.transcribe(segment).words } catch {
            NSLog("Yapr: transcription failed: \(error.localizedDescription)")
            return
        }

        let pause = energy.trailingSilence >= LiveTranscriber.pauseToCommit
        if final || pause || duration >= LiveTranscriber.maxSegment {
            var commit = words
            var cut = segment.count
            if !final && !pause {
                // Forced commit mid-speech: keep the tail live, cut between the last committed word and the next.
                commit = words.filter { $0.end < duration - LiveTranscriber.keepLive }
                if commit.isEmpty { commit = words }
                else if let next = words.dropFirst(commit.count).first {
                    cut = Int((commit.last!.end + next.start) / 2 * LiveTranscriber.rate)
                }
            }
            guard !commit.isEmpty else {
                if final || duration > 4 { trim(segment.count); silenceCarried += duration }
                publish(committed: [], live: [])
                return
            }
            let leading = commit.first!.start + silenceCarried
            let separator = !hasText ? "" : (leading >= LiveTranscriber.paragraphPause ? "\n\n" : " ")
            hasText = true
            silenceCarried = cut == segment.count ? max(0, duration - commit.last!.end) : 0
            trim(cut)
            let remainder = cut == segment.count ? [] : Array(words.dropFirst(commit.count))
            let text = separator + commit.map(\.text).joined(separator: " ")
            DispatchQueue.main.async { [onCommit] in onCommit?(text) }
            publish(committed: commit.map(\.text), live: remainder.map(\.text))
        } else {
            publish(committed: [], live: words.map(\.text))
        }
    }

    private func trim(_ n: Int) {
        lock.lock(); pending.removeFirst(min(n, pending.count)); lock.unlock()
    }

    private func publish(committed: [String], live: [String]) {
        DispatchQueue.main.async { [onUpdate] in onUpdate?(committed, live) }
    }

    /// 50 ms blocks against Phonon's own speech gate (max(0.004, 0.18 x peak RMS)), with a floor for quiet rooms.
    private static func energy(_ a: [Float]) -> (hasSpeech: Bool, trailingSilence: Double) {
        let block = 800, nb = a.count / block
        guard nb > 0 else { return (false, 0) }
        var rms = [Float](repeating: 0, count: nb)
        a.withUnsafeBufferPointer { p in
            for b in 0..<nb {
                var s: Float = 0
                for i in (b * block)..<((b + 1) * block) { s += p[i] * p[i] }
                rms[b] = (s / Float(block)).squareRoot()
            }
        }
        let peak = rms.max() ?? 0
        guard peak > 0.008 else { return (false, Double(nb) * 0.05) }
        let gate = max(0.004, 0.18 * peak)
        var quiet = 0
        for v in rms.reversed() { if v <= gate { quiet += 1 } else { break } }
        return (true, Double(quiet) * 0.05)
    }
}
