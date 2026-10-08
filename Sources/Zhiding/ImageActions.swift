import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import ZhidingCore

@MainActor
extension AppCoordinator {
    func captureRegion() {
        guard let screen = NSScreen.mouseScreen else {
            notice = "当前没有可用显示器，无法开始区域截图。"
            return
        }
        let displayID = screen.displayID
        perform { [self] token in
            let mode = CGDisplayCopyDisplayMode(displayID)
            let width = mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            let height = mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            let reservation = try await budget.reserve(bytes: Limits.surfaceBytes(width: width, height: height, copies: 5), kind: .screenshot)
            do {
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                guard requestScreenshotPermission(), gate.accepts(token) else { throw ZhidingError.cancelled }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard gate.accepts(token), let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw ZhidingError.cancelled
                }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let pixelWidth = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded(.up))
                let pixelHeight = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded(.up))
                try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: pixelWidth, height: pixelHeight, copies: 5))
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                let config = SCStreamConfiguration()
                config.width = pixelWidth; config.height = pixelHeight
                config.showsCursor = false; config.capturesAudio = false
                config.colorSpaceName = CGColorSpace.sRGB
                config.pixelFormat = kCVPixelFormatType_32BGRA
                var background: CGImage? = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard gate.accepts(token), let backgroundImage = background else { throw ZhidingError.cancelled }
                try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: backgroundImage.width, height: backgroundImage.height, copies: 5))
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                let rect = await withCheckedContinuation { continuation in
                    let panel = SelectionOverlay(image: backgroundImage, screen: screen) { rect in continuation.resume(returning: rect) }
                    overlay = panel
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                }
                overlay = nil
                guard gate.accepts(token), let rect else { throw ZhidingError.cancelled }
                let crop = try Geometry.pixelCrop(selection: rect, logicalSize: screen.frame.size,
                                                  pixelSize: CGSize(width: backgroundImage.width, height: backgroundImage.height))
                let image = try await Task.detached(priority: .userInitiated) {
                    try ImageCodec.independentCopy(backgroundImage, crop: crop)
                }.value
                background = nil
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: image.width, height: image.height, copies: 2))
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                makeStaticPin(image, logicalSize: rect.size, reservation: reservation, screen: screen)
            } catch {
                await budget.release(reservation)
                throw error is ZhidingError ? error : ZhidingError.captureFailed
            }
        }
    }

    func requestScreenshotPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "区域截图需要屏幕录制权限"
        alert.informativeText = "用于冻结当前屏幕并截取选区。画面不上传、不自动保存。窗口镜像与图片导入可独立使用。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "继续请求权限")
        alert.addButton(withTitle: "打开屏幕录制设置")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            _ = CGRequestScreenCaptureAccess()
            if CGPreflightScreenCaptureAccess() { return true }
            openScreenRecordingSettings()
        case .alertThirdButtonReturn: openScreenRecordingSettings()
        default: break
        }
        return false
    }

    @discardableResult
    func openPrivacySettings() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// 打开「隐私与安全性」下指定面板：按候选深链顺序尝试，全部失败退回系统设置根页，不伪装成功。
    func openPrivacyPane(_ candidates: [String], guidance: String) {
        // open 返回 true 只说明系统接收了 URL，不代表面板定位或授权成功。
        notice = guidance
        for link in candidates {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
        if !openPrivacySettings() {
            notice = "无法自动打开系统设置。" + guidance
        }
    }

    /// 仅供用户查看或撤销旧版辅助功能授权；不发出新的授权请求。
    func openAccessibilitySettings() {
        openPrivacyPane(["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                         "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"],
                        guidance: "请在系统设置 → 隐私与安全性 → 辅助功能查看旧版授权。当前版本不再需要该权限。")
    }

    /// 定位到「隐私与安全性 → 屏幕录制」。
    func openScreenRecordingSettings() {
        openPrivacyPane(["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                         "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"],
                        guidance: "请在系统设置 → 隐私与安全性 → 屏幕录制（或屏幕与系统音频录制）中允许“置顶”。若系统要求重启，请先保存贴图后手动重启。")
    }

    /// 打开「隐私与安全性」根页。
    func openPrivacySecuritySettings() {
        openPrivacyPane(["x-apple.systempreferences:com.apple.preference.security",
                         "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"],
                        guidance: "请在系统设置 → 隐私与安全性查看权限。窗口镜像由系统选择器逐次授权，图片导入不需要屏幕权限。")
    }

    func importImage() {
        perform { [self] token in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url, gate.accepts(token) else { throw ZhidingError.cancelled }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let reservation = try await budget.reserve(bytes: Limits.encodedBytes + 1, kind: .screenshot)
            do {
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                let data = try await Task.detached(priority: .userInitiated) {
                    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard attributes.isRegularFile == true else { throw ZhidingError.unsupportedImage }
                    guard (attributes.fileSize ?? Int.max) <= Limits.encodedBytes else { throw ZhidingError.imageTooLarge }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: Limits.encodedBytes + 1) ?? Data()
                    guard data.count <= Limits.encodedBytes else { throw ZhidingError.imageTooLarge }
                    return data
                }.value
                try await decodeAndPin(data, allowTIFF: false, externalCopy: true, reservation: reservation, token: token)
            } catch {
                await budget.release(reservation)
                throw error is ZhidingError ? error : ZhidingError.invalidImage
            }
        }
    }

    func pasteImage() {
        perform { [self] token in
            let reservation = try await budget.reserve(bytes: Limits.encodedBytes + 1, kind: .screenshot)
            do {
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                let pasteboard = NSPasteboard.general
                guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else {
                    throw ZhidingError.unsupportedImage
                }
                try await decodeAndPin(data, allowTIFF: type == .tiff, externalCopy: false, reservation: reservation, token: token)
            } catch { await budget.release(reservation); throw error }
        }
    }

    private func decodeAndPin(_ data: Data, allowTIFF: Bool, externalCopy: Bool, reservation: UUID, token: UUID) async throws {
        let info = try await Task.detached { try ImageCodec.inspect(data, allowTIFF: allowTIFF) }.value
        let work = try Limits.surfaceBytes(width: info.width, height: info.height, copies: 4)
        try await budget.resize(reservation, bytes: work + data.count)
        guard gate.accepts(token) else { throw ZhidingError.cancelled }
        let image = try await Task.detached(priority: .userInitiated) { try ImageCodec.decode(data, allowTIFF: allowTIFF) }.value
        guard gate.accepts(token), let screen = NSScreen.mouseScreen else { throw ZhidingError.cancelled }
        try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: image.width, height: image.height, copies: 2))
        guard gate.accepts(token) else { throw ZhidingError.cancelled }
        makeStaticPin(image, logicalSize: CGSize(width: image.width, height: image.height), reservation: reservation, screen: screen, exported: externalCopy)
        if info.frameCount > 1 { message("此图片包含多帧，本次仅贴出第一帧。") }
    }

    func makeStaticPin(_ image: CGImage, logicalSize: CGSize, reservation: UUID, screen: NSScreen, exported: Bool = false) {
        serial += 1
        let record = PinRecord(kind: .screenshot, budgetID: reservation, name: "贴图 \(serial)", logicalSize: logicalSize)
        record.image = image
        record.exported = exported
        attach(record, screen: screen)
    }

    func export(_ record: PinRecord, toClipboard: Bool) {
        guard let image = record.image else { return }
        perform { [self] _ in
            var destination: URL?
            if !toClipboard {
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "Zhiding-\(Int(Date().timeIntervalSince1970))-\(record.name.replacingOccurrences(of: " ", with: "-")).png"
                guard panel.runModal() == .OK, let url = panel.url else { throw ZhidingError.cancelled }
                destination = url
            }
            let workID = try await budget.reserve(bytes: Limits.surfaceBytes(width: image.width, height: image.height, copies: 3))
            do {
                let data = try await Task.detached(priority: .userInitiated) { try ImageCodec.png(image) }.value
                if let destination {
                    let scoped = destination.startAccessingSecurityScopedResource()
                    defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                    do { try await Task.detached { try data.write(to: destination, options: .atomic) }.value }
                    catch { throw ZhidingError.exportFailed }
                    record.exported = true
                } else {
                    guard !privacyHidden else { throw ZhidingError.cancelled }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                }
                await budget.release(workID)
            } catch { await budget.release(workID); throw error }
        }
    }

    func freeze(_ record: PinRecord) {
        perform { [self] token in
            guard let renderer = record.renderer, renderer.hasFrame, let screen = record.panel?.screen ?? NSScreen.main else {
                throw ZhidingError.captureFailed
            }
            let size = renderer.drawableSize
            let reservation = try await budget.reserve(bytes: Limits.surfaceBytes(width: Int(size.width), height: Int(size.height), copies: 4), kind: .screenshot)
            do {
                guard gate.accepts(token), !record.closing else { throw ZhidingError.cancelled }
                let image = try renderer.snapshot()
                try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: image.width, height: image.height, copies: 2))
                guard gate.accepts(token) else { throw ZhidingError.cancelled }
                makeStaticPin(image, logicalSize: record.logicalSize, reservation: reservation, screen: screen)
            } catch { await budget.release(reservation); throw error }
        }
    }
}
