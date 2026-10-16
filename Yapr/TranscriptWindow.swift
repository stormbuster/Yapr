import AppKit

/// The transcript, set in EB Garamond on paper: a borderless window after stormbuster/borderless (full-size content view,
/// hidden title bar, draggable from anywhere that is not text), black copy and close glyphs top right, generous margins,
/// and a scroll bar that only appears while scrolling.
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var open: [TranscriptWindowController] = []

    private let textView = MarginDragTextView()
    private let scrollView = NSScrollView()
    private let text: String
    private let copyButton = CircleIconButton(symbol: "yapr.copy", label: "Copy transcript")
    private let closeButton = CircleIconButton(symbol: "xmark", label: "Close")
    private var copiedReset: DispatchWorkItem?
    private static let measure: CGFloat = 520        // the text column: about 66 characters a line
    private static let minSideMargin: CGFloat = 64
    private static let verticalMargin: CGFloat = 76   // NSTextView applies it above and below the text

    static func show(text: String, fileURL: URL?) {
        let controller = TranscriptWindowController(text: text, fileURL: fileURL)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(text: String, fileURL: URL?) {
        self.text = text
        let window = BorderlessWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 780),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.backgroundColor = Palette.paperNS
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 320)
        window.title = fileURL?.deletingPathExtension().lastPathComponent ?? "Yapr"
        window.representedURL = fileURL
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        if let screen = window.screen {   // cascade a little so successive transcripts do not stack exactly
            let shift = CGFloat(TranscriptWindowController.open.count % 6) * 24
            window.setFrameOrigin(NSPoint(x: window.frame.minX + shift, y: min(window.frame.minY - shift, screen.visibleFrame.maxY)))
        }
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.paperNS.cgColor
        window.contentView = container

        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .dark
        scrollView.automaticallyAdjustsContentInsets = false
        NotificationCenter.default.addObserver(self, selector: #selector(keepOverlayScrollers),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.selectedTextAttributes = [.backgroundColor: Palette.inkNS.withAlphaComponent(0.10)]
        textView.textStorage?.setAttributedString(TranscriptWindowController.typeset(text))
        scrollView.documentView = textView
        container.addSubview(scrollView)

        // Top right, right to left: close, then copy.
        let size = CircleIconButton.size, inset: CGFloat = 20, gap: CGFloat = 4
        closeButton.frame.origin = NSPoint(x: container.bounds.maxX - inset - size, y: container.bounds.maxY - inset - size)
        copyButton.frame.origin = NSPoint(x: closeButton.frame.minX - gap - size, y: closeButton.frame.minY)
        for button in [copyButton, closeButton] {
            button.autoresizingMask = [.minXMargin, .minYMargin]
            container.addSubview(button)
        }
        closeButton.onPress = { [weak window] in window?.performClose(nil) }
        copyButton.onPress = { [weak self] in self?.copyTranscript() }
        copyButton.isHidden = text.isEmpty

        layoutMargins()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func typeset(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.32
        paragraph.paragraphSpacing = 17
        paragraph.hyphenationFactor = 0
        paragraph.lineBreakStrategy = .pushOut
        var font = Typography.garamond(21)
        // Old-style figures and common ligatures, as a typesetter would have it.
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector],
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOnSelector],
        ]
        font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: 21) ?? font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.inkNS,
            .paragraphStyle: paragraph,
            .kern: 0.1,
            .ligature: 1,
        ]
        if text.isEmpty {
            var quiet = attrs
            quiet[.font] = Typography.garamond(21, italic: true)
            quiet[.foregroundColor] = Palette.inkNS.withAlphaComponent(0.45)
            return NSAttributedString(string: "Nothing was heard.", attributes: quiet)
        }
        // The file separates paragraphs with a blank line; on the page, paragraph spacing does that job.
        let page = text.replacingOccurrences(of: "\n\n", with: "\n")
        return NSAttributedString(string: page, attributes: attrs)
    }

    /// Centres a column of at most `measure` points, with at least `minSideMargin` on either side.
    private func layoutMargins() {
        guard let width = window?.contentView?.bounds.width else { return }
        let side = max(TranscriptWindowController.minSideMargin, (width - TranscriptWindowController.measure) / 2)
        textView.textContainerInset = NSSize(width: side, height: TranscriptWindowController.verticalMargin)
        textView.invalidateTextContainerOrigin()
    }

    /// Copies the whole transcript as plain text, paragraphs separated by a blank line as in the file, and briefly
    /// shows a check mark.
    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.setSymbol("checkmark")
        copyButton.setAccessibilityLabel("Copied")
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.copyButton.setSymbol("yapr.copy")
            self?.copyButton.setAccessibilityLabel("Copy transcript")
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }

    #if DEBUG
    func debugButtons() -> (copy: CircleIconButton, close: CircleIconButton, copyAction: () -> Void) {
        (copyButton, closeButton, { [weak self] in self?.copyTranscript() })
    }
    #endif

    func windowDidResize(_ notification: Notification) { layoutMargins() }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        TranscriptWindowController.open.removeAll { $0 === self }
    }

    @objc private func keepOverlayScrollers() { scrollView.scrollerStyle = .overlay }
}

private final class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }   // Esc closes
}

/// An NSTextView whose margins drag the window, so the page can be moved from anywhere that is not text.
private final class MarginDragTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let column = bounds.insetBy(dx: textContainerInset.width, dy: 0)
        let textBottom = textContainerInset.height + (layoutManager.map { $0.usedRect(for: textContainer!).height } ?? 0)
        if !column.contains(p) || p.y < textContainerInset.height || p.y > textBottom {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
