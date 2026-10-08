import AppKit
import SwiftUI
import Combine
import ScreenCaptureKit
import ZhidingCore

@main
struct ZhidingApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator()
        app.delegate = coordinator
        withExtendedLifetime(coordinator) { app.run() }
    }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    @Published var records: [PinRecord] = []
    @Published var isBusy = false
    @Published private(set) var privacyHidden = false
    @Published private(set) var privacyReason = "隐私保护"
    @Published var notice: String?
    private var privacyPromptPresented = false
    let budget = ResourceBudget()
    let hotkeys = HotKeyService()
    lazy var picker = WindowPicker()
    var gate = OperationGate()
    var overlay: SelectionOverlay?
    var operationTask: Task<Void, Never>?
    var serial = 0
    var experimentalAcknowledged = false
    var terminating = false
    private var statusItem: NSStatusItem?
    private var actions: [MenuAction] = []
    private var observers: [NSObjectProtocol] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    var pinPickerWindow: NSWindow?
    let smokeMode = CommandLine.arguments.contains("--smoke-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "置顶")
        item.button?.toolTip = "置顶 · 截图贴图与窗口镜像"
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        picker.onUnexpectedChange = { [weak self] stream in
            guard let self, let record = self.records.first(where: { $0.session?.stream === stream }) else { return }
            Task { await self.stopMirror(record, clear: true) }
        }
        rebuildMenu()
        if smokeMode {
            Task { await runSmokeTest() }
            return
        }
        hotkeys.onCommand = { [weak self] command in self?.execute(command) }
        hotkeys.start()
        installLifecycleObservers()
        if !UserDefaults.standard.bool(forKey: "didShowIntroduction") {
            showManager()
            UserDefaults.standard.set(true, forKey: "didShowIntroduction")
        }
    }

    func execute(_ command: AppCommand) {
        switch command {
        case .screenshot: captureRegion()
        case .mirror: selectMirror()
        case .paste: pasteImage()
        case .toggleAll: toggleAll()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems(); actions.removeAll()
        let pins = records.filter { $0.kind == .screenshot }.count
        let mirrors = records.filter { $0.kind == .mirror }.count
        let active = records.filter { $0.session?.isCapturing == true }.count
        let hidden = records.filter { $0.session?.isCapturing == true && $0.hidden }.count
        menu.addItem(withTitle: "贴图 \(pins)/20 · 镜像 \(mirrors)/3", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "捕获中 \(active) 路（隐藏 \(hidden) 路）", action: nil, keyEquivalent: "")
        if isBusy { menu.addItem(withTitle: "正在处理，请完成或取消当前操作", action: nil, keyEquivalent: "") }
        if privacyHidden {
            menu.addItem(withTitle: "保护原因：\(privacyReason)", action: nil, keyEquivalent: "")
            add("恢复显示（镜像需重新选择）") { [weak self] in self?.resumePrivacy() }
        }
        menu.addItem(.separator())
        for command in AppCommand.allCases where command != .toggleAll {
            let suffix = hotkeys.bindings[command].map { $0.enabled ? "    \($0.display)" : "" } ?? ""
            add(command.title + suffix) { [weak self] in self?.execute(command) }
        }
        add("导入图片…") { [weak self] in self?.importImage() }
        add("原窗口置顶不可用 · 查看说明…") { [weak self] in self?.selectWindowPin() }
        menu.addItem(.separator())
        add("置顶内容管理…") { [weak self] in self?.showManager() }
        add(records.contains(where: { !$0.hidden }) ? "全部隐藏" : "全部显示") { [weak self] in self?.toggleAll() }
        add("解除全部鼠标穿透") { [weak self] in self?.clearAllPassThrough() }
        add("关闭全部…") { [weak self] in self?.closeAllConfirmed() }
        menu.addItem(.separator())
        add("设置与使用说明…") { [weak self] in self?.showSettings() }
        add("退出置顶") { NSApp.terminate(nil) }
    }
    private func add(_ title: String, handler: @escaping () -> Void) {
        let action = MenuAction(handler)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = action
        statusItem?.menu?.addItem(item)
    }

    func refresh() {
        objectWillChange.send()
        picker.streamCount = records.filter { $0.session?.requiresPicker == true }.count
        for record in records { record.panel?.surface.refresh() }
    }

    /// 用户主动操作的统一入口：在原地确认恢复，取消时不读屏、不读取剪贴板、不展示旧内容。
    func prepareForUserAction(confirmResume: (() -> Bool)? = nil) -> Bool {
        guard !terminating else { return false }
        guard !isBusy, !picker.isPresenting else {
            notice = "正在选择或处理内容，请先完成或取消系统选择器；已有贴图不需要关闭。"
            if !smokeMode { showManager() }
            return false
        }
        guard privacyHidden else { return true }
        guard !privacyPromptPresented else { return false }
        privacyPromptPresented = true
        defer { privacyPromptPresented = false }
        let generation = gate.generation
        let accepted = confirmResume?() ?? confirmPrivacyResume()
        guard accepted else {
            notice = "已取消本次操作，原内容继续保持隐藏。"
            return false
        }
        // 模态确认期间仍可能收到新的休眠或保护事件，旧确认不能解除新的保护。
        guard !terminating, generation == gate.generation else {
            notice = "保护状态已变化，本次未恢复显示，请返回桌面后重试。"
            return false
        }
        resumePrivacy()
        return true
    }

    private func confirmPrivacyResume() -> Bool {
        guard !smokeMode else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "恢复显示并继续本次操作？"
        alert.informativeText = "保护原因：\(privacyReason)。继续会显示原先可见的贴图和镜像占位，不会自动重启镜像；之前手动隐藏的内容仍保持隐藏。"
        alert.addButton(withTitle: "取消，保持隐藏")
        alert.addButton(withTitle: "恢复显示并继续")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func perform(_ work: @escaping @MainActor (UUID) async throws -> Void) {
        guard prepareForUserAction() else { return }
        notice = nil
        isBusy = true
        let token = gate.generation
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.operationTask = nil; self.refresh() }
            do { try await work(token) }
            catch {
                guard self.gate.accepts(token), (error as? ZhidingError) != .cancelled else { return }
                self.message((error as? LocalizedError)?.errorDescription ?? "操作失败，请重试。")
            }
        }
    }

    func attach(_ record: PinRecord, screen: NSScreen) {
        let panel = PinPanel(record: record, screen: screen) { [weak self, weak record] action in
            guard let self, let record else { return }
            self.handle(action, record: record)
        }
        record.panel = panel
        if let renderer = record.renderer { panel.surface.install(renderer) }
        records.insert(record, at: 0)
        panel.orderFrontRegardless()
        refresh()
    }

    func handle(_ action: PinAction, record: PinRecord) {
        guard !record.closing else { return }
        if privacyHidden {
            switch action {
            case .close, .hide, .stop: break
            default: guard prepareForUserAction() else { return }
            }
        }
        switch action {
        case .close: Task { await close(record) }
        case .hide: setHidden(record, true)
        case .copy: export(record, toClipboard: true)
        case .save: export(record, toClipboard: false)
        case .freeze: freeze(record)
        case .stop: Task { await stopMirror(record, clear: false) }
        case .passThrough:
            record.clickThrough.toggle(); record.panel?.ignoresMouseEvents = record.clickThrough
        case .opacity: record.opacity = record.opacity <= 0.21 ? 1 : max(0.2, (record.opacity * 20 - 1).rounded() / 20)
        }
        refresh()
    }

    func setHidden(_ record: PinRecord, _ hidden: Bool) {
        if !hidden && privacyHidden { guard prepareForUserAction() else { return } }
        record.hidden = hidden
        if hidden || privacyHidden { record.panel?.orderOut(nil) } else { record.panel?.orderFrontRegardless() }
        record.session?.setHidden(hidden)
        refresh()
    }
    func toggleAll() {
        let wasProtected = privacyHidden
        guard prepareForUserAction() else { return }
        if wasProtected { return }
        let hide = records.contains { !$0.hidden }
        for record in records { setHidden(record, hide) }
    }
    func clearAllPassThrough() {
        for record in records { record.clickThrough = false; record.panel?.ignoresMouseEvents = false }
        refresh()
    }
    func locate(_ record: PinRecord) {
        guard prepareForUserAction() else { return }
        setHidden(record, false)
        if let panel = record.panel, let screen = NSScreen.mouseScreen {
            panel.setFrame(Geometry.constrain(panel.frame, to: screen.visibleFrame), display: true)
        }
    }

    func close(_ record: PinRecord) async {
        guard !record.closing else { return }
        record.closing = true
        record.panel?.orderOut(nil)
        if let session = record.session, !(await session.stop(clearFrame: true)) {
            record.closing = false
            refresh()
            return
        }
        record.renderer?.invalidate(clearFrame: true)
        await record.renderer?.drain()
        record.session = nil
        record.panel?.close()
        record.panel = nil
        record.image = nil
        record.renderer = nil
        records.removeAll { $0.id == record.id }
        await budget.release(record.budgetID)
        refresh()
    }

    func stopMirror(_ record: PinRecord, clear: Bool) async {
        guard let session = record.session else { return }
        record.status = "正在停止…"
        if await session.stop(clearFrame: clear) {
            record.status = clear ? "已停止，画面已清除" : "已停止"
        }
        refresh()
    }

    func closeAllConfirmed() {
        guard confirmDiscard() else { return }
        gate.invalidate()
        overlay?.finish(nil)
        picker.cancelRequest()
        Task { for record in records { await close(record) } }
    }
    func confirmDiscard() -> Bool {
        let count = records.filter(\.hasUnsavedImage).count
        guard count > 0 else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "还有 \(count) 张贴图未导出"
        alert.informativeText = "关闭后不会恢复。复制到剪贴板不代表已保存文件。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "丢弃并继续")
        alert.addButton(withTitle: "返回管理")
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { showManager() }
        return response == .alertSecondButtonReturn
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if smokeMode { return .terminateNow }
        guard !terminating, confirmDiscard() else { return .terminateCancel }
        terminating = true
        gate.protect()
        overlay?.finish(nil)
        picker.cancelRequest()
        hotkeys.stop()
        Task {
            await operationTask?.value
            for record in records { await close(record) }
            picker.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func protectPrivacy(reason: String = "用户请求隐私保护") {
        gate.protect()
        privacyReason = reason
        privacyHidden = true
        notice = nil
        overlay?.finish(nil)
        picker.cancelRequest()
        for record in records {
            record.panel?.orderOut(nil)
            record.renderer?.invalidate(clearFrame: true)
            if let session = record.session {
                // 停止当时的会话，迟到任务不能误停用户后来重选的新会话。
                record.status = "正在停止…"
                Task { [weak self, weak record] in
                    let stopped = await session.stop(clearFrame: true)
                    guard let self, let record, record.session === session else { return }
                    if stopped { record.status = "已停止，画面已清除" }
                    self.refresh()
                }
            }
        }
        refresh()
    }
    func resumePrivacy() {
        guard !terminating else { return }
        gate.resume()
        privacyHidden = false
        notice = nil
        for record in records where !record.hidden { record.panel?.orderFrontRegardless() }
        refresh()
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.willSleepNotification, "系统即将休眠"),
                               (NSWorkspace.screensDidSleepNotification, "显示器进入休眠"),
                               (NSWorkspace.sessionDidResignActiveNotification, "用户会话离开")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.protectPrivacy(reason: reason) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.gate.invalidate()
                self.overlay?.finish(nil)
                self.picker.cancelRequest()
                for record in self.records {
                    if let panel = record.panel, let screen = panel.screen ?? NSScreen.main {
                        panel.setFrame(Geometry.constrain(panel.frame, to: screen.visibleFrame), display: true)
                    }
                }
            }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.protectPrivacy(reason: "系统报告内存压力") }
        }
        pressureSource = source
        source.resume()
    }

    func message(_ text: String) {
        guard !privacyHidden, !terminating, !smokeMode else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "置顶"
        alert.informativeText = text
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func showManager() {
        if managerWindow == nil {
            managerWindow = makeWindow(title: "置顶内容管理", view: AnyView(ManagerView(app: self)), size: CGSize(width: 760, height: 520))
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = managerWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "置顶设置", view: AnyView(SettingsView(app: self, hotkeys: hotkeys)), size: CGSize(width: 630, height: 560))
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
    func makeWindow(title: String, view: AnyView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // 用户主动打开的管理/设置窗口可盖住自有参考面板，避免入口被遮挡。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.contentView = NSHostingView(rootView: view)
        window.minSize = size
        window.center()
        return window
    }
}

@MainActor
private final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}
