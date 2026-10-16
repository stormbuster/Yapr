import AppKit
import Combine

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: CirclePanelController!
    private let settingsWindow = SettingsWindowController()
    private var cancellables: Set<AnyCancellable> = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Typography.registerFonts()
        AudioDevices.startObserving()
        NSApp.mainMenu = AppDelegate.keyEquivalentMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = AppDelegate.statusImage(recording: false)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Yapr"
        }

        panel = CirclePanelController(model: model) { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }

        model.onTranscript = { text, url in TranscriptWindowController.show(text: text, fileURL: url) }
        model.$phase.map { $0 == .recording }.removeDuplicates().sink { [weak self] recording in
            self?.statusItem.button?.image = AppDelegate.statusImage(recording: recording)
            self?.statusItem.button?.contentTintColor = recording ? .systemRed : nil
        }.store(in: &cancellables)

        model.loadModel()
        #if DEBUG
        DebugHarness.runIfRequested(model: model, panel: panel, settings: settingsWindow)
        #endif
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Yapr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() { settingsWindow.show() }

    private static func statusImage(recording: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Yapr")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// An agent app shows no menu bar, but a main menu still routes ⌘C, ⌘A, ⌘F and ⌘W to the transcript window.
    private static func keyEquivalentMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app
        app.addItem(withTitle: "Quit Yapr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window"); windowItem.submenu = window
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return main
    }
}
