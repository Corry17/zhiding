import AppKit
import Combine
import ZhidingCore

@MainActor
final class PinRecord: ObservableObject, Identifiable {
    let id = UUID()
    let kind: PinKind
    let budgetID: UUID
    let name: String
    let createdAt = Date()
    @Published var hidden = false
    @Published var clickThrough = false
    @Published var opacity = 1.0
    @Published var exported = false
    @Published var status = "静态"
    @Published var lastFrameAt: Date?
    var image: CGImage?
    var logicalSize: CGSize
    var panel: PinPanel?
    var session: MirrorSession?
    var renderer: MirrorRenderer?
    var closing = false

    init(kind: PinKind, budgetID: UUID, name: String, logicalSize: CGSize) {
        self.kind = kind; self.budgetID = budgetID; self.name = name; self.logicalSize = logicalSize
    }
    var hasUnsavedImage: Bool { kind == .screenshot && !exported }
}

enum PinAction { case close, hide, copy, save, freeze, stop, passThrough, opacity }

@MainActor
final class PinPanel: NSPanel {
    let surface: PinSurface
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(record: PinRecord, screen: NSScreen, action: @escaping (PinAction) -> Void) {
        let fitted = Geometry.fit(record.logicalSize, inside: CGSize(width: 640, height: 480))
        let size = CGSize(width: max(160, fitted.width), height: max(100, fitted.height))
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        surface = PinSurface(record: record, action: action)
        super.init(contentRect: Geometry.constrain(CGRect(origin: origin, size: size), to: screen.visibleFrame),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isRestorable = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = surface
        title = record.name
        setAccessibilityLabel(record.name)
    }
}

@MainActor
final class ActionButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, help: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        toolTip = help
        setAccessibilityLabel(help)
        bezelStyle = .texturedRounded
        isBordered = false
        imagePosition = .imageOnly
        target = self; action = #selector(invoke)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
}

@MainActor
private final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PinSurface: NSView {
    private weak var record: PinRecord?
    private let actionHandler: (PinAction) -> Void
    private let imageView = PassiveImageView()
    private let top = NSVisualEffectView()
    private let bottom = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(wrappingLabelWithString: "正在连接…")
    private let grip = ResizeGrip()
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var renderer: MirrorRenderer?
    private var subscriptions = Set<AnyCancellable>()
    private var freezeButton: NSButton?

    init(record: PinRecord, action: @escaping (PinAction) -> Void) {
        self.record = record; actionHandler = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        addSubview(placeholder)
        for material in [top, bottom] {
            material.material = .hudWindow
            material.blendingMode = .withinWindow
            material.state = .active
            addSubview(material)
        }
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        top.addSubview(titleLabel)
        let close = ActionButton(symbol: "xmark", help: "关闭并丢弃此内容") { action(.close) }
        top.addSubview(close)
        NSLayoutConstraint.activate([close.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -2),
                                     close.centerYAnchor.constraint(equalTo: top.centerYAnchor)])
        let controls = NSStackView()
        controls.spacing = 1
        controls.orientation = .horizontal
        controls.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(controls)
        let actions: [(String, String, PinAction)] = record.kind == .screenshot
            ? [("doc.on.doc", "复制原图", .copy), ("square.and.arrow.down", "保存 PNG", .save)]
            : [("camera", "最后有效帧转贴图", .freeze), ("stop.circle", "停止捕获", .stop)]
        for (symbol, help, actionID) in actions + [
            ("circle.lefthalf.filled", "透明度：每次降低 5%，最低 20% 后恢复 100%", .opacity),
            ("cursorarrow.rays", "开启鼠标穿透，可从菜单解除", .passThrough),
            ("eye.slash", "隐藏此内容", .hide)
        ] {
            let button = ActionButton(symbol: symbol, help: help) { action(actionID) }
            controls.addArrangedSubview(button)
            if actionID == .freeze { freezeButton = button }
        }
        NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: bottom.centerXAnchor),
                                     controls.centerYAnchor.constraint(equalTo: bottom.centerYAnchor)])
        addSubview(grip)
        record.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    func install(_ renderer: MirrorRenderer) {
        self.renderer?.removeFromSuperview()
        self.renderer = renderer
        addSubview(renderer, positioned: .below, relativeTo: placeholder)
        needsLayout = true
        refresh()
    }

    func refresh() {
        guard let record else { return }
        titleLabel.stringValue = "\(record.status) · \(record.name)"
        titleLabel.toolTip = record.lastFrameAt.map { "最后有效帧：\($0.formatted(date: .omitted, time: .standard))；仅供查看" }
        if let image = record.image, imageView.image == nil {
            imageView.image = NSImage(cgImage: image, size: record.logicalSize)
        }
        imageView.alphaValue = record.opacity
        renderer?.alphaValue = record.opacity
        let hasContent = record.image != nil || (renderer?.hasFrame ?? false)
        placeholder.isHidden = hasContent
        placeholder.stringValue = record.kind == .mirror ? "\(record.status)\n仅查看，请切回原应用操作" : ""
        freezeButton?.isEnabled = renderer?.hasFrame ?? false
        top.isHidden = !hovering && record.kind == .screenshot
        bottom.isHidden = !hovering
        grip.isHidden = !hovering
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        renderer?.frame = bounds
        placeholder.frame = CGRect(x: 12, y: max(12, bounds.midY - 28), width: max(0, bounds.width - 24), height: 56)
        top.frame = CGRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28)
        titleLabel.frame = CGRect(x: 10, y: 6, width: max(0, bounds.width - 44), height: 16)
        bottom.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 30)
        grip.frame = CGRect(x: bounds.width - 18, y: 0, width: 18, height: 18)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor
private final class ResizeGrip: NSView {
    private var startPoint = CGPoint.zero
    private var startFrame = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 5, y: 4)); path.line(to: CGPoint(x: 14, y: 13))
        path.move(to: CGPoint(x: 10, y: 4)); path.line(to: CGPoint(x: 14, y: 8))
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        startPoint = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, startFrame.width > 0 else { return }
        let point = NSEvent.mouseLocation
        let scale = max(160 / startFrame.width, 100 / startFrame.height,
                        (startFrame.width + point.x - startPoint.x) / startFrame.width)
        let size = CGSize(width: startFrame.width * scale, height: startFrame.height * scale)
        let rect = CGRect(x: startFrame.minX, y: startFrame.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(Geometry.constrain(rect, to: (window.screen ?? NSScreen.main)?.visibleFrame ?? rect), display: true)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    @MainActor static var mouseScreen: NSScreen? { screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main }
}
