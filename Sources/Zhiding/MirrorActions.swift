import AppKit
import ScreenCaptureKit
import ZhidingCore

@MainActor
extension AppCoordinator {
    func selectMirror(replacing existing: PinRecord? = nil) {
        #if !DEBUG
        notice = "镜像尚未通过锁屏与权限验收，当前 Release 构建不开放此实验功能。请使用开发构建完成 G01—G06 验证。"
        if !smokeMode { showManager() }
        return
        #else
        guard prepareForUserAction() else { return }
        if !experimentalAcknowledged {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "窗口镜像 · 本机开发验证"
            alert.informativeText = "此功能只能查看，不能操作源窗口。锁屏检测与全屏兼容性尚未完成实机验收。仅用非敏感窗口测试，离开电脑前主动停止镜像；不要将此构建对外分发。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "使用非敏感内容测试")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            experimentalAcknowledged = true
        }
        perform { [self] token in
            var reservation: UUID?
            var attached: PinRecord?
            do {
                if let existing {
                    guard !existing.closing, records.contains(where: { $0 === existing }) else { throw ZhidingError.cancelled }
                    await stopMirror(existing, clear: false)
                    guard existing.session?.isCapturing != true else { throw ZhidingError.captureFailed }
                    reservation = existing.budgetID
                } else { reservation = try await budget.reserve(bytes: 0, kind: .mirror) }
                guard gate.accepts(token), existing?.closing != true else { throw ZhidingError.cancelled }
                let filter = try await picker.pick()
                guard gate.accepts(token), existing?.closing != true, let reservation,
                      let screen = NSScreen.mouseScreen else { throw ZhidingError.cancelled }
                let logical = filter.contentRect.size
                let native = CGSize(width: logical.width * CGFloat(filter.pointPixelScale),
                                    height: logical.height * CGFloat(filter.pointPixelScale))
                let output = try Geometry.mirrorOutput(native)
                existing?.renderer?.invalidate(clearFrame: true)
                await existing?.renderer?.drain()
                try await budget.resize(reservation, bytes: Limits.surfaceBytes(width: Int(output.width), height: Int(output.height), copies: 8))
                guard gate.accepts(token), existing?.closing != true else { throw ZhidingError.cancelled }
                let renderer = try MirrorRenderer(outputSize: output)
                serial += 1
                let record = existing ?? PinRecord(kind: .mirror, budgetID: reservation, name: "镜像 \(serial)", logicalSize: logical)
                record.logicalSize = logical
                record.status = "正在连接…"
                record.lastFrameAt = nil
                record.renderer = renderer
                let session = MirrorSession.make(filter: filter, output: output, renderer: renderer)
                record.session = session
                renderer.onFrame = { [weak self, weak record, weak session] date in
                    guard let self, let record, let session, record.session === session,
                          !record.closing, !self.privacyHidden else { return }
                    if record.lastFrameAt == nil || date.timeIntervalSince(record.lastFrameAt!) >= 1 {
                        record.lastFrameAt = date
                        record.status = "实时 · 仅查看"
                        self.refresh()
                    }
                }
                session.onState = { [weak self, weak record, weak session] state in
                    guard let record, let session, record.session === session, !record.closing else { return }
                    record.status = state
                    self?.refresh()
                }
                session.onEnded = { [weak self] in self?.refresh() }
                if existing == nil { attach(record, screen: screen) }
                else { record.panel?.surface.install(renderer); setHidden(record, false) }
                attached = record
                refresh()
                Task { [weak record] in
                    try? await Task.sleep(for: .seconds(10))
                    if let record, record.lastFrameAt == nil, record.status == "正在连接…" {
                        record.status = "尚未收到画面，可等待或关闭"
                    }
                }
                try await session.start()
                guard gate.accepts(token), !record.closing else {
                    _ = await session.stop(clearFrame: true)
                    throw ZhidingError.cancelled
                }
                refresh()
            } catch {
                if let attached {
                    await stopMirror(attached, clear: true)
                    attached.status = "捕获失败，请重新选择"
                } else if existing == nil, let reservation { await budget.release(reservation) }
                throw error is ZhidingError ? error : ZhidingError.captureFailed
            }
        }
        #endif
    }
}
