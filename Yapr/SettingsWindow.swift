import AppKit
import SwiftUI

final class SettingsWindowController {
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Yapr Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(settings: .shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var inputs = AudioDevices.inputs()
    @State private var outputs = AudioDevices.outputs()

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Input", selection: $settings.inputDeviceUID) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                    if !settings.inputDeviceUID.isEmpty && !inputs.contains(where: { $0.uid == settings.inputDeviceUID }) {
                        Text(settings.inputDeviceName.isEmpty ? "Disconnected device" : "\(settings.inputDeviceName) (disconnected)")
                            .tag(settings.inputDeviceUID)
                    }
                }
                Picker("Output", selection: $settings.outputDeviceUID) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(outputs) { Text($0.name).tag($0.uid) }
                    if !settings.outputDeviceUID.isEmpty && !outputs.contains(where: { $0.uid == settings.outputDeviceUID }) {
                        Text(settings.outputDeviceName.isEmpty ? "Disconnected device" : "\(settings.outputDeviceName) (disconnected)")
                            .tag(settings.outputDeviceUID)
                    }
                }
                Toggle(isOn: $settings.passThrough) {
                    Text("Pass-through")
                    Text("Hear yourself on the output while recording. Use headphones to avoid feedback.")
                }
            }
            Section("Transcripts") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text((settings.transcriptsFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.transcriptsFolder.path)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: settings.transcriptsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([settings.transcriptsFolder])
                }
            }
            Section {
                Text("Transcription runs on this Mac with Phonon 2 by Fermion Research (CC-BY-4.0). Nothing leaves your computer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { settings.reconnectDevices(); inputs = AudioDevices.inputs(); outputs = AudioDevices.outputs() }
        .onReceive(NotificationCenter.default.publisher(for: AudioDevices.didChange)) { _ in
            settings.reconnectDevices()
            inputs = AudioDevices.inputs()
            outputs = AudioDevices.outputs()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.transcriptsFolder
        if panel.runModal() == .OK, let url = panel.url { settings.transcriptsFolder = url }
    }
}
