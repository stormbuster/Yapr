#if DEBUG
import AVFoundation
import AppKit
import Combine

/// End-to-end check without a microphone or a mouse. With YAPR_SNAPSHOTS=<dir> and YAPR_FEED=<16 kHz mono float wav> set,
/// Yapr opens its panel, "records" the file in real time through the live transcriber, stops, and writes PNG snapshots of
/// each stage to <dir>.
enum DebugHarness {
    private static var cancellable: AnyCancellable?
    private static var phaseLog: AnyCancellable?

    static func runIfRequested(model: AppModel, panel: CirclePanelController, settings: SettingsWindowController) {
        let env = ProcessInfo.processInfo.environment
        if env["YAPR_MIC_TEST"] != nil { runMicTest(model: model); return }
        guard let dir = env["YAPR_SNAPSHOTS"] else { return }
        let t0 = Date()
        phaseLog = model.$phase.removeDuplicates { a, b in
            if case .transcribingFile = a, case .transcribingFile = b { return true }
            return a == b
        }.sink { phase in
            FileHandle.standardError.write(Data("YAPR_PHASE \(String(format: "%6.1f", Date().timeIntervalSince(t0))) s  \(phase)\n".utf8))
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        if let file = env["YAPR_FILE"] { runFile(URL(fileURLWithPath: file), model: model, panel: panel, out: out); return }
        guard let feedPath = env["YAPR_FEED"] else { return }
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

    /// YAPR_FILE=<audio or video>: the drop path, snapshotting the circle while words drift in.
    private static func runFile(_ url: URL, model: AppModel, panel: CirclePanelController, out: URL) {
        cancellable = model.$phase.first { $0 == .ready }.sink { _ in
            cancellable = nil
            panel.show()
            let t0 = Date()
            model.transcribeFiles([url])
            var shots = 0
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                if case .transcribingFile(_, let p) = model.phase {
                    if shots < 4, model.words.count > 3 * (shots + 1) { shots += 1; snap(panel.contentView, out, "file-\(shots)") }
                    _ = p
                } else if model.phase == .ready {
                    timer.invalidate()
                    print("YAPR_FILE_DONE \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
                    after(0.8) {
                        snap(panel.contentView, out, "file-after")
                        snap(TranscriptWindowController.open.last?.window?.contentView, out, "file-transcript")
                        if let controller = TranscriptWindowController.open.last {
                            let b = controller.debugButtons()
                            let saved = NSPasteboard.general.string(forType: .string)   // put the user's clipboard back afterwards
                            b.copyAction()
                            let copied = NSPasteboard.general.string(forType: .string) ?? ""
                            NSPasteboard.general.clearContents()
                            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
                            print("YAPR_COPIED \(copied.count) chars, starts: \(copied.prefix(40))")
                            b.close.debugShow(.hover)
                            snap(controller.window?.contentView, out, "buttons-copied-closehover")
                            b.close.debugShow(.pressed)
                            snap(controller.window?.contentView, out, "buttons-closepressed")
                        }
                        print("YAPR_HARNESS_DONE")
                        fflush(stdout)
                    }
                } else if case .failed(let m) = model.phase {
                    timer.invalidate(); print("YAPR_FILE_FAILED \(m)"); fflush(stdout)
                }
            }
        }
    }

    /// YAPR_MIC_TEST=1 YAPR_MIC_LOG=<file>: record from the real microphone for 10 s, log what happens, then quit.
    private static func runMicTest(model: AppModel) {
        var maxLevel: Float = 0
        levelLog = model.$level.sink { maxLevel = max(maxLevel, $0) }
        // @Published delivers before the property changes, so act on the next turn of the run loop.
        cancellable = model.$phase.first { $0 == .ready }.receive(on: DispatchQueue.main).sink { _ in
            cancellable = nil
            AudioCapture.log("mic test: starting; saved input=\(Settings.shared.inputDeviceUID) name=\(Settings.shared.inputDeviceName)")
            model.toggleRecording()
            after(2) { AudioCapture.log("mic test: double tap -> \(model.debugDoubleTap())") }
            let seconds = Double(ProcessInfo.processInfo.environment["YAPR_MIC_SECONDS"] ?? "") ?? 10
            after(seconds) {
                AudioCapture.log("mic test: phase=\(model.phase) maxLevel=\(maxLevel) words=\(model.words.map(\.text).joined(separator: " "))")
                if model.phase == .recording { model.toggleRecording() }
                after(3) { AudioCapture.log("mic test: done, phase=\(model.phase)"); NSApp.terminate(nil) }
            }
        }
    }
    private static var levelLog: AnyCancellable?

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
