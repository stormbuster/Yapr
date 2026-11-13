import AVFoundation
import AppKit
import SwiftUI

/// Microphone and system-audio permission. macOS 26 only shows a permission prompt to the app in front, and a request
/// it refuses to prompt for leaves no entry under Privacy & Security; Yapr is a menu bar app whose circle never takes
/// focus, so permission is asked for from a small window of its own, from a button press, with Yapr in front.
enum Permissions {
    enum Status { case granted, undecided, denied }

    static func status(for source: AudioSource) -> Status {
        switch source {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .undecided
            default: return .denied
            }
        case .system:
            return SystemAudioPermission.status
        }
    }

    /// Asks macOS; the completion runs on the main queue with the outcome. Yapr is made a regular app in front first:
    /// macOS 26 refuses to prompt for a menu bar (accessory) app even when its window is in front.
    static func request(_ source: AudioSource, completion: @escaping (Status) -> Void) {
        bringToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ask(source, completion) }
    }

    /// While a permission is being asked for, Yapr is an ordinary app: Dock icon, menu bar, in front.
    static func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
    }

    static func backToMenuBar() {
        NSApp.setActivationPolicy(.accessory)
    }

    private static func ask(_ source: AudioSource, _ completion: @escaping (Status) -> Void) {
        AudioCapture.log("asking for \(source); active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")
        switch source {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted ? .granted : status(for: .microphone)) }
            }
        case .system:
            SystemAudioPermission.request { _ in DispatchQueue.main.async { completion(status(for: .system)) } }
        }
    }

    static func openSettings(for source: AudioSource) {
        let pane = source == .microphone ? "Privacy_Microphone" : "Privacy_AudioCapture"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

/// System Audio Recording has no public API to check or request permission; macOS only asks when a process tap
/// starts. Like Apple's own sample code for process taps, Yapr asks the privacy service directly when it is available,
/// and otherwise reports .undecided and lets the tap trigger the prompt.
enum SystemAudioPermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Permissions.Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .undecided }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undecided
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            // Fall back to what macOS does on its own: starting a tap asks once.
            let tap = SystemAudioTap()
            do { try tap.start() } catch {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tap.stop(); completion(status == .granted) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
    }
}

/// The window that asks: what Yapr needs and why, one button, and where to go when access is off. It closes by
/// itself, and continues what was asked for, as soon as access is given (also when given in System Settings).
final class PermissionWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var poll: Timer?
    private var onGranted: (() -> Void)?
    private let state = PermissionState()

    func show(for source: AudioSource, then onGranted: (() -> Void)? = nil) {
        self.onGranted = onGranted
        state.source = source
        state.status = Permissions.status(for: source)
        if state.status == .granted { finish(); return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = Palette.paperNS
            w.appearance = NSAppearance(named: .aqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: PermissionView(state: state, ask: { [weak self] in self?.ask() }))
            w.center()
            window = w
        }
        Permissions.bringToFront()
        window?.makeKeyAndOrderFront(nil)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func ask() {
        if state.status == .denied { Permissions.openSettings(for: state.source); return }
        state.asking = true
        Permissions.request(state.source) { [weak self] status in
            guard let self else { return }
            self.state.asking = false
            self.state.status = status
            if status == .granted { self.finish() }
        }
    }

    private func refresh() {
        let status = Permissions.status(for: state.source)
        if status != state.status, !state.asking { state.status = status }
        if status == .granted { finish() }
    }

    private func finish() {
        poll?.invalidate(); poll = nil
        window?.orderOut(nil)
        Permissions.backToMenuBar()
        let next = onGranted
        onGranted = nil
        next?()
    }

    #if DEBUG
    /// Test hook: render the window's content for a source and status into a PNG.
    func debugSnapshot(_ source: AudioSource, _ status: Permissions.Status, to url: URL) {
        state.source = source; state.status = status
        let view = NSHostingView(rootView: PermissionView(state: state, ask: {}))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate(); poll = nil
        Permissions.backToMenuBar()
        onGranted = nil
    }
}

final class PermissionState: ObservableObject {
    @Published var source: AudioSource = .microphone
    @Published var status: Permissions.Status = .undecided
    @Published var asking = false
}

private struct PermissionView: View {
    @ObservedObject var state: PermissionState
    let ask: () -> Void

    private var title: String {
        switch (state.source, state.status) {
        case (.microphone, .denied): return "Microphone access is off"
        case (.microphone, _): return "Yapr needs your microphone"
        case (.system, .denied): return "System audio access is off"
        case (.system, _): return "Yapr needs to hear your Mac"
        }
    }

    private var message: String {
        switch (state.source, state.status) {
        case (.microphone, .denied):
            return "Turn on Yapr under System Settings › Privacy & Security › Microphone. This window closes by itself once it is on."
        case (.microphone, _):
            return "To transcribe what you say, macOS has to let Yapr hear your microphone. Audio never leaves this Mac."
        case (.system, .denied):
            return "Turn on Yapr under System Settings › Privacy & Security › Screen & System Audio Recording, in System Audio Recording Only."
        case (.system, _):
            return "To transcribe what this Mac plays, macOS has to allow Yapr to record system audio. Audio never leaves this Mac."
        }
    }

    private var button: String {
        state.status == .denied ? "Open System Settings" : (state.source == .microphone ? "Allow Microphone" : "Allow System Audio")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Typography.garamondFont(26))
                .foregroundStyle(Palette.ink)
            Text(message)
                .font(Typography.garamondFont(17))
                .foregroundStyle(Palette.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if state.status == .denied {
                Text("Yapr not in the list? Quit it from its menu bar icon, open it again from the Applications folder, and press the button again.")
                    .font(Typography.garamondFont(14, italic: true))
                    .foregroundStyle(Palette.pencil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: ask) {
                    Text(button)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Palette.ink))
                }
                .buttonStyle(.plain)
                .disabled(state.asking)
                .opacity(state.asking ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 440)
        .background(Palette.paper)
    }
}
