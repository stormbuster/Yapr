import Foundation

/// A plain UTF-8 text file in the transcripts folder, appended to as phrases are committed so nothing is lost on a crash.
final class TranscriptFile {
    let url: URL
    private let handle: FileHandle
    private(set) var text = ""

    /// `baseName` defaults to "Yapr <date> at <time>"; a transcribed file passes its own name.
    init(folder: URL, baseName: String? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = baseName ?? "Yapr \(formatter.string(from: Date()))"
        var candidate = folder.appendingPathComponent("\(base).txt")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).txt"); n += 1
        }
        url = candidate
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ s: String) {
        text += s
        try? handle.write(contentsOf: Data(s.utf8))
    }

    /// Closes the file with a trailing newline; an empty recording leaves no file behind.
    func close() {
        if text.isEmpty {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        } else {
            try? handle.write(contentsOf: Data("\n".utf8))
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
