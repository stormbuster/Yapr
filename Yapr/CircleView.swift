import SwiftUI

/// The round panel: a big microphone at rest; while recording the microphone becomes a smaller stop button and the words
/// Phonon 2 hears drift in above it.
struct CircleView: View {
    @ObservedObject var model: AppModel
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void
    @State private var dropTargeted = false

    static let diameter: CGFloat = 300
    static let margin: CGFloat = 32          // room for the shadow
    static var windowSize: CGFloat { diameter + margin * 2 }

    private var isRecording: Bool { model.phase == .recording || model.phase == .finishing }
    private var fileJob: (name: String, progress: Double)? {
        if case .transcribingFile(let name, let progress) = model.phase { return (name, progress) }
        return nil
    }
    /// Recording or transcribing a file: the button shrinks to the bottom and words drift in above it.
    private var isListening: Bool { isRecording || fileJob != nil }

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.paper)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
                .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
            DragHandle(onBegan: onDragBegan, onEnded: onDragEnded)
                .clipShape(Circle())
            content
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .frame(width: Self.windowSize, height: Self.windowSize)
    }

    private var acceptsDrops: Bool {
        switch model.phase {
        case .recording, .finishing: return false
        default: return true
        }
    }

    private var showDropHint: Bool { dropTargeted && acceptsDrops }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrops else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.transcribeFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
        return true
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .downloading(let p):
            StatusText(title: "Fetching Phonon 2", detail: "\(Int(p * 100))%  ·  330 MB, once")
            Circle()
                .trim(from: 0, to: p)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(14)
                .animation(.linear(duration: 0.2), value: p)
                .allowsHitTesting(false)
        case .preparing(let message):
            StatusText(title: message, detail: nil)
            BreathingRing().padding(14).allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: 14) {
                Text(message)
                    .font(Typography.garamondFont(17))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .allowsHitTesting(false)
                Button(action: model.retry) {
                    Text("Try again").font(Typography.garamondFont(16, italic: true)).underline().foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 220)
        case .ready, .recording, .finishing, .transcribingFile:
            ZStack {
                WordsView(words: model.words)
                    .frame(width: 228, height: 128)
                    .offset(y: -40)
                    .opacity(isListening ? 1 : 0)
                Text(fileJob?.name ?? "")
                    .font(Typography.garamondFont(14, italic: true))
                    .foregroundStyle(Palette.pencil)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 200)
                    .offset(y: 37)
                    .opacity(fileJob == nil ? 0 : 1)
                    .allowsHitTesting(false)
                Text(showDropHint ? "Drop to transcribe" : "Yapr")
                    .font(Typography.garamondFont(17, italic: true))
                    .foregroundStyle(showDropHint ? Palette.ink : Palette.pencil)
                    .contentTransition(.opacity)
                    .offset(y: 104)
                    .opacity(isListening ? 0 : 1)
                    .allowsHitTesting(false)
                Circle()
                    .strokeBorder(Palette.ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [3, 5]))
                    .padding(12)
                    .opacity(showDropHint ? 1 : 0)
                    .scaleEffect(showDropHint ? 1 : 1.04)
                    .animation(.easeOut(duration: 0.2), value: showDropHint)
                    .allowsHitTesting(false)
                MicButton(compact: isListening, busy: model.phase == .finishing, level: model.level,
                          fileProgress: fileJob?.progress,
                          action: fileJob == nil ? model.toggleRecording : model.cancelFile)
                    .offset(y: isListening ? 82 : 0)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isListening)
            .animation(.easeOut(duration: 0.2), value: showDropHint)
        }
    }
}

private struct StatusText: View {
    let title: String
    let detail: String?
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Typography.garamondFont(20)).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(Typography.garamondFont(15, italic: true)).foregroundStyle(Palette.pencil).monospacedDigit() }
        }
        .multilineTextAlignment(.center)
        .frame(width: 220)
        .allowsHitTesting(false)
    }
}

private struct BreathingRing: View {
    @State private var on = false
    var body: some View {
        Circle()
            .stroke(Palette.ink.opacity(on ? 0.35 : 0.06), lineWidth: 1.5)
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever()) { on = true } }
    }
}

private struct MicButton: View {
    let compact: Bool
    let busy: Bool
    let level: Float
    let fileProgress: Double?          // a file being transcribed: progress ring, and the button cancels
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let size: CGFloat = compact ? 64 : 124
        let icon = fileProgress != nil ? "xmark" : compact ? "stop.fill" : "mic.fill"
        Button(action: action) {
            ZStack {
                // Level rings: confidence that the microphone is hearing you.
                Circle()
                    .stroke(Palette.ink.opacity(0.10), lineWidth: 1)
                    .scaleEffect(1 + CGFloat(level) * 0.9)
                Circle()
                    .fill(Palette.ink.opacity(0.06))
                    .scaleEffect(1 + CGFloat(level) * 0.45)
                // Reading progress through a dropped file.
                Circle()
                    .trim(from: 0, to: fileProgress ?? 0)
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-9)
                    .opacity(fileProgress == nil ? 0 : 1)
                    .animation(.linear(duration: 0.2), value: fileProgress)
                Circle()
                    .fill(Palette.ink)
                Image(systemName: icon)
                    .font(.system(size: compact ? 20 : 46, weight: fileProgress != nil ? .medium : .regular))
                    .foregroundStyle(Palette.paper)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(busy ? 0.4 : 1)
            }
            .frame(width: size, height: size)
            .scaleEffect(hover ? 1.03 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.easeOut(duration: 0.09), value: level)
        .help(fileProgress != nil ? "Stop transcribing this file" : compact ? "Stop and show the transcript" : "Start transcribing")
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The last few dozen words, bottom-aligned and centred line by line, fading out towards the top. Words still being
/// revised are pencil-grey; committed words turn to ink.
private struct WordsView: View {
    let words: [DisplayWord]
    var body: some View {
        WordFlow(spacing: 5, lineSpacing: 1) {
            ForEach(words) { word in
                Text(word.text)
                    .font(Typography.garamondFont(19))
                    .foregroundStyle(word.final ? Palette.ink : Palette.ink.opacity(0.45))
                    .fixedSize()
                    // Words leave at the top, where the mask has already faded them; animating that would leave ghosts.
                    .transition(.asymmetric(insertion: .modifier(active: Arrive(on: false), identity: Arrive(on: true)),
                                            removal: .identity))
            }
        }
        .animation(.easeOut(duration: 0.4), value: words)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

private struct Arrive: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).blur(radius: on ? 0 : 5).offset(y: on ? 0 : 7)
    }
}

/// Wraps words into lines, centres each line and aligns the block to the bottom; overflow rises out of the top.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 228, height: proposal.height ?? 128)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            let gap = lines[lines.count - 1].isEmpty ? 0 : spacing
            if gap > 0 && x + gap + s.width > bounds.width { lines.append([]); x = 0 }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + s.width
            lines[lines.count - 1].append(i)
        }
        let lineHeight = sizes.map(\.height).max() ?? 0
        let total = CGFloat(lines.count) * lineHeight + CGFloat(max(0, lines.count - 1)) * lineSpacing
        var y = bounds.maxY - total
        for line in lines {
            let width = line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, line.count - 1))
            var lx = bounds.midX - width / 2
            for i in line {
                subviews[i].place(at: CGPoint(x: lx, y: y), anchor: .topLeading, proposal: ProposedViewSize(sizes[i]))
                lx += sizes[i].width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}

/// Drags the panel from anywhere on the circle (except the buttons on top of it).
private struct DragHandle: NSViewRepresentable {
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ view: DragHandleView, context: Context) {
        view.onBegan = onBegan
        view.onEnded = onEnded
    }
}

final class DragHandleView: NSView {
    var onBegan: () -> Void = {}
    var onEnded: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = bounds.width / 2
        return hypot(p.x - bounds.midX, p.y - bounds.midY) <= r ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type != .leftMouseUp {
            let m = NSEvent.mouseLocation
            let dx = m.x - startMouse.x, dy = m.y - startMouse.y
            if !moved && hypot(dx, dy) < 3 { continue }
            if !moved { moved = true; onBegan() }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if moved { onEnded() }
    }
}
