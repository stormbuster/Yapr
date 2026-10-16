#if DEBUG
import AVFoundation
import AppKit
import Combine

/// End-to-end check without a microphone or a mouse. With YAPR_SNAPSHOTS=<dir> and YAPR_FEED=<16 kHz mono float wav> set,
/// Yapr opens its panel, "records" the file in real time through the live transcriber, stops, and writes PNG snapshots of
/// each stage to <dir>.
enum DebugHarness {
    private static var cancellable: AnyCancellable?

    static func runIfRequested(model: AppModel, panel: CirclePanelController, settings: SettingsWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["YAPR_SNAPSHOTS"], let feedPath = env["YAPR_FEED"] else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        cancellable = model.$phase.first { $0 == .ready }.sink { _ in
            cancellable = nil
            let samples = read(URL(fileURLWithPath: feedPath))
            let seconds = Double(samples.count) / 16_000
            panel.show()
            after(0.8) {
                snap(panel.contentView, out, "1-neutral")
                model.debugStart(feeding: samples)
            }
            after(0.8 + seconds * 0.35) { snap(panel.contentView, out, "2-recording-a") }
            after(0.8 + seconds * 0.7) { snap(panel.contentView, out, "3-recording-b") }
            after(0.8 + seconds + 0.3) { model.toggleRecording() }   // stop right after the last word
            after(0.8 + seconds + 3.5) {
                snap(panel.contentView, out, "4-neutral-after")
                snap(TranscriptWindowController.open.last?.window?.contentView, out, "5-transcript")
                settings.show()
            }
            after(0.8 + seconds + 4.5) {
                snap(settings.window?.contentView, out, "6-settings")
                print("YAPR_HARNESS_DONE")
            }
        }
    }

    private static func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    private static func read(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return [] }
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    private static func snap(_ view: NSView?, _ dir: URL, _ name: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("YAPR_SNAP_MISSING \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        print("YAPR_SNAP \(name)")
    }
}
#endif
