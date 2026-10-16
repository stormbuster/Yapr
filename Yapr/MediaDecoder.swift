import AVFoundation
import UniformTypeIdentifiers

enum MediaDecoderError: LocalizedError {
    case noAudio(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .noAudio(let name): return "“\(name)” has no sound to transcribe."
        case .unreadable(let name): return "Yapr could not read “\(name)”."
        }
    }
}

/// Reads the first audio track of any audio or video file AVFoundation understands (mp3, m4a, wav, aiff, flac, caf,
/// mp4, mov, m4v, …) as mono 16 kHz float samples, which is what Phonon 2 takes.
enum MediaDecoder {
    static func canRead(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// Streams the file as mono 16 kHz blocks; blocking, call off the main thread. `block` gets the samples and how far
    /// through the file they reach (0...1), and may throw to stop reading.
    static func read(_ url: URL, block: ([Float], Double) throws -> Void) throws {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let (track, duration) = try loadTrack(asset, name: name)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw MediaDecoderError.unreadable(name) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaDecoderError.unreadable(name) }
        reader.add(output)
        guard reader.startReading() else { throw MediaDecoderError.unreadable(name) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var total = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(data)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            total += samples.count
            let reached = duration > 0 ? min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration) : 0
            try block(samples, reached)
        }
        guard reader.status == .completed else { throw MediaDecoderError.unreadable(name) }
        guard total > 0 else { throw MediaDecoderError.noAudio(name) }
    }

    private static func loadTrack(_ asset: AVURLAsset, name: String) throws -> (AVAssetTrack, Double) {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(AVAssetTrack, Double), Error> = .failure(MediaDecoderError.unreadable(name))
        Task.detached {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration).seconds
                if let track = tracks.first { result = .success((track, duration.isFinite ? duration : 0)) }
                else { result = .failure(MediaDecoderError.noAudio(name)) }
            } catch {
                result = .failure(MediaDecoderError.unreadable(name))
            }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
