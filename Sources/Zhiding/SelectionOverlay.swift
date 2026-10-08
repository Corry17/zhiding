import AppKit
import ZhidingCore

@MainActor
final class SelectionOverlay: NSPanel {
    private var completion: ((CGRect?) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: CGImage, screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        isRestorable = false
        let selection = SelectionView(image: image, size: screen.frame.size)
        selection.onFinish = { [weak self] rect in self?.finish(rect) }
        contentView = selection
        makeFirstResponder(selection)
    }

    func finish(_ rect: CGRect?) {
        guard let callback = completion else { return }
        completion = nil
        orderOut(nil)
        close()
        contentView = nil
        callback(rect)
    }
}

@MainActor
private final class SelectionView: NSView {
    private let image: NSImage
    private let pixels: CGSize
    private var start: CGPoint?
    private var end: CGPoint?
    var onFinish: ((CGRect?) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, size: CGSize) {
        self.image = NSImage(cgImage: image, size: size)
        pixels = CGSize(width: image.width, height: image.height)
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { nil }

    private var selection: CGRect? {
        guard let start, let end else { return nil }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        drawImage()
        NSColor.black.withAlphaComponent(0.36).setFill()
        bounds.fill()
        if let selection, !selection.isNull {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            drawImage()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2; path.stroke()
        }
        var text = "拖拽选择，松开置顶 · Esc 取消 · 本次仅截取当前屏幕"
        if let selection, let crop = try? Geometry.pixelCrop(selection: selection, logicalSize: bounds.size, pixelSize: pixels) {
            text += "   \(Int(crop.width)) × \(Int(crop.height)) px"
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: NSColor.white,
                                                        .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        (text as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: attributes)
    }
    private func drawImage() {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        guard let selection, selection.width >= 2, selection.height >= 2 else { start = nil; needsDisplay = true; return }
        onFinish?(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
