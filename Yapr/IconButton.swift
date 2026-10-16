import AppKit

/// A black glyph on paper that shows a light grey circle when hovered, a darker one while pressed.
final class CircleIconButton: NSView {
    enum Look { case idle, hover, pressed }

    var onPress: () -> Void = {}
    private let imageView = NSImageView()
    private let circle = CALayer()
    private var tracking: NSTrackingArea?
    private var hovering = false
    private(set) var look: Look = .idle { didSet { updateCircle() } }

    static let size: CGFloat = 32

    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: CircleIconButton.size, height: CircleIconButton.size))
        wantsLayer = true
        circle.frame = bounds
        circle.cornerRadius = bounds.width / 2
        layer?.addSublayer(circle)

        imageView.frame = bounds
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = Palette.inkNS
        addSubview(imageView)
        setSymbol(symbol)

        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        updateCircle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    #if DEBUG
    /// Test hook: show a state without a mouse.
    func debugShow(_ look: Look) { self.look = look }
    #endif

    private func updateCircle() {
        let alpha: CGFloat = switch look { case .idle: 0; case .hover: 0.07; case .pressed: 0.15 }
        CATransaction.begin()
        CATransaction.setAnimationDuration(look == .pressed ? 0.05 : 0.15)
        circle.backgroundColor = Palette.inkNS.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; if look != .pressed { look = .hover } }
    override func mouseExited(with event: NSEvent) { hovering = false; if look != .pressed { look = .idle } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Press tracking like a button: the circle darkens while the mouse is down inside, and the action fires on release inside.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        look = .pressed
        var inside = true
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp { break }
            look = inside ? .pressed : .idle
        }
        hovering = inside
        look = inside ? .hover : .idle
        if inside { onPress() }
    }

    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}
