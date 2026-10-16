import Foundation
import PhononCoreML

/// Transcribes an audio or video file of any length with flat memory: the file is read in blocks, cut into chunks of
/// 25–30 s at the quietest moment (so no word is split), and each chunk goes through Phonon 2 as soon as it is complete.
/// Words and text are reported as they are recognised, which lets the circle show them drifting in as with live speech.
final class FileTranscriber {
    struct Cancelled: Error {}

    private let transcriber: Transcriber
    private let lock = NSLock()
    private var cancelled = false

    private static let rate = 16_000
    private static let chunkMin = 25.0, chunkMax = 30.0
    private static let paragraphPause = 2.5

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Blocking. `onText` gets each piece of transcript with its leading separator, `onWords` the words of that piece,
    /// `onProgress` how far through the file reading has got. Throws `Cancelled` after `cancel()`.
    func run(_ url: URL, onText: (String) -> Void, onWords: ([String]) -> Void, onProgress: (Double) -> Void) throws {
        var buffer: [Float] = []
        var hasText = false
        var carriedQuiet = 0.0         // silence at the end of the previous chunk, seconds

        func transcribe(_ count: Int) throws {
            let chunk = Array(buffer[..<count])
            buffer.removeFirst(count)
            let seconds = Double(count) / Double(FileTranscriber.rate)
            guard !chunk.allSatisfy({ abs($0) < 1e-4 }) else { carriedQuiet += seconds; return }
            let words = try transcriber.transcribe(chunk).words
            guard !words.isEmpty else { carriedQuiet += seconds; return }
            // Paragraphs come from silence measured in the audio: word end times are not reliable for this, since
            // sentence-final punctuation can be stamped late.
            let quiet = Silence(chunk)
            var text = ""
            for (i, w) in words.enumerated() {
                if hasText {
                    let pause = i == 0 ? carriedQuiet + quiet.leading(until: w.start) : quiet.longest(from: words[i - 1].start, to: w.start)
                    text += pause >= FileTranscriber.paragraphPause ? "\n\n" : " "
                }
                text += w.text
                hasText = true
            }
            carriedQuiet = quiet.trailing(after: words.last!.start)
            onText(text)
            onWords(words.map(\.text))
        }

        try MediaDecoder.read(url) { samples, reached in
            if isCancelled { throw Cancelled() }
            buffer.append(contentsOf: samples)
            onProgress(reached)
            if buffer.count >= Int(FileTranscriber.chunkMax * Double(FileTranscriber.rate)) {
                try transcribe(FileTranscriber.quietestCut(buffer))
            }
        }
        if isCancelled { throw Cancelled() }
        if !buffer.isEmpty { try transcribe(buffer.count) }
        onProgress(1)
    }

    /// Quiet 50 ms blocks of one chunk, against Phonon's speech gate (max(0.004, 0.18 x peak RMS)).
    private struct Silence {
        static let block = 0.05
        let quiet: [Bool]

        init(_ a: [Float]) {
            let n = Int(Silence.block * Double(FileTranscriber.rate)), nb = a.count / n
            var rms = [Float](repeating: 0, count: nb)
            a.withUnsafeBufferPointer { p in
                for b in 0..<nb {
                    var s: Float = 0
                    for i in (b * n)..<((b + 1) * n) { s += p[i] * p[i] }
                    rms[b] = (s / Float(n)).squareRoot()
                }
            }
            let gate = max(0.004, 0.18 * (rms.max() ?? 0))
            quiet = rms.map { $0 <= gate }
        }

        private func index(_ t: Double) -> Int { min(quiet.count, max(0, Int(t / Silence.block))) }

        /// Longest run of quiet between two times, seconds.
        func longest(from a: Double, to b: Double) -> Double {
            var best = 0, run = 0
            for i in index(a)..<max(index(a), index(b)) { run = quiet[i] ? run + 1 : 0; best = max(best, run) }
            return Double(best) * Silence.block
        }
        /// Quiet from the start of the chunk up to `t` (or the first sound).
        func leading(until t: Double) -> Double {
            var run = 0
            for i in 0..<index(t) { if quiet[i] { run += 1 } else { break } }
            return Double(run) * Silence.block
        }
        /// Quiet at the end of the chunk, not reaching back before `t`.
        func trailing(after t: Double) -> Double {
            var run = 0
            for i in stride(from: quiet.count - 1, through: index(t), by: -1) { if quiet[i] { run += 1 } else { break } }
            return Double(run) * Silence.block
        }
    }

    /// The middle of the quietest 50 ms block between 25 and 30 s.
    private static func quietestCut(_ a: [Float]) -> Int {
        let block = 800
        let lo = Int(chunkMin * Double(rate)) / block, hi = min(a.count, Int(chunkMax * Double(rate))) / block
        var best = hi * block, bestRMS = Float.greatestFiniteMagnitude
        a.withUnsafeBufferPointer { p in
            for b in lo..<hi {
                var s: Float = 0
                for i in (b * block)..<((b + 1) * block) { s += p[i] * p[i] }
                if s < bestRMS { bestRMS = s; best = b * block + block / 2 }
            }
        }
        return best
    }
}
