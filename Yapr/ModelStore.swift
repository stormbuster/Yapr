import CryptoKit
import Foundation

/// Fetches the Phonon-2 Core ML model folder from Hugging Face once (pinned revision, SHA-256 checked) into
/// ~/Library/Application Support/Yapr/Phonon-2-CoreML.
final class ModelStore {
    static let shared = ModelStore()

    private static let repo = "FermionResearch/Phonon-2-CoreML"
    private static let revision = "1143812fd4236522232a8c33e3115f0577e3cd7d"

    private struct File { let path: String; let size: Int64; let sha256: String }
    private static let files: [File] = [
        File(path: "manifest.json", size: 1_428, sha256: "ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089"),
        File(path: "decoder.bin", size: 13_301_279, sha256: "36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70"),
        File(path: "Phonon-2.mlpackage/Manifest.json", size: 617, sha256: "6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429"),
        File(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 2_500_482,
             sha256: "4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a"),
        File(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 329_186_560,
             sha256: "93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b"),
        File(path: "LICENSE-WEIGHTS-CC-BY-4.0.txt", size: 18_657, sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        File(path: "NOTICE", size: 3_084, sha256: "b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be"),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    let directory: URL
    private let staging: URL
    private var observation: NSKeyValueObservation?
    private var downloaded: Int64 = 0   // bytes of finished files; touched by one download at a time

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yapr", isDirectory: true)
        directory = support.appendingPathComponent("Phonon-2-CoreML", isDirectory: true)
        staging = support.appendingPathComponent("Phonon-2-CoreML.partial", isDirectory: true)
    }

    var isInstalled: Bool {
        ModelStore.files.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == f.size
        }
    }

    /// Progress (0...1) and completion arrive on the main queue.
    func download(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let pending = ModelStore.files.filter { f in
            ((try? fm.attributesOfItem(atPath: staging.appendingPathComponent(f.path).path))?[.size] as? NSNumber)?.int64Value != f.size
        }
        downloaded = ModelStore.totalBytes - pending.reduce(0) { $0 + $1.size }
        let total = Double(ModelStore.totalBytes)

        func next(_ queue: ArraySlice<File>) {
            guard let file = queue.first else {
                do {
                    try? fm.removeItem(at: directory)
                    try fm.moveItem(at: staging, to: directory)
                    DispatchQueue.main.async { completion(nil) }
                } catch { DispatchQueue.main.async { completion(error) } }
                return
            }
            let url = URL(string: "https://huggingface.co/\(ModelStore.repo)/resolve/\(ModelStore.revision)/\(file.path)")!
            let destination = staging.appendingPathComponent(file.path)
            let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, error in
                self?.observation = nil
                do {
                    if let error { throw error }
                    guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw NSError(domain: "Yapr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hugging Face refused \(file.path)."])
                    }
                    guard try ModelStore.sha256(of: tmp) == file.sha256 else {
                        throw NSError(domain: "Yapr", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(file.path) failed its checksum."])
                    }
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: tmp, to: destination)
                    self?.downloaded += file.size
                    next(queue.dropFirst())
                } catch {
                    DispatchQueue.main.async { completion(error) }
                }
            }
            let base = downloaded
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let fraction = (Double(base) + p.fractionCompleted * Double(file.size)) / total
                DispatchQueue.main.async { progress(fraction) }
            }
            task.resume()
        }
        next(pending[...])
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
