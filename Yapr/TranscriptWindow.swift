import AppKit

/// The transcript, set in EB Garamond on paper: a borderless window after stormbuster/borderless (full-size content view,
/// hidden title bar, draggable from anywhere that is not text), a black close glyph top right, generous margins, and a
/// scroll bar that only appears while scrolling.
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var open: [TranscriptWindowController] = []

    private let textView = MarginDragTextView()
    private let scrollView = NSScrollView()
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

        let close = CloseButton()
        close.target = window
        close.action = #selector(NSWindow.performClose(_:))
        close.frame = NSRect(x: container.bounds.maxX - 22 - 28, y: container.bounds.maxY - 22 - 28, width: 28, height: 28)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(close)

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

/// A plain black × glyph.
private final class CloseButton: NSButton {
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(config)
        contentTintColor = Palette.inkNS
        alphaValue = 0.85
        setAccessibilityLabel("Close")
        toolTip = "Close"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.85 }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
