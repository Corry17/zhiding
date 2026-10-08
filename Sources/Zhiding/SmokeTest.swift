import AppKit
import CoreVideo
import ZhidingCore

@MainActor
extension AppCoordinator {
    func runSmokeTest() async {
        do {
            guard let screen = NSScreen.main,
                  let context = CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw SmokeFailure(message: "无法创建测试图像或连接窗口系统")
            }
            context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
            let image = context.makeImage()!
            for _ in 0..<10 {
                let id = try await budget.reserve(bytes: Limits.surfaceBytes(width: 128, height: 96, copies: 2), kind: .screenshot)
                makeStaticPin(image, logicalSize: CGSize(width: 128, height: 96), reservation: id, screen: screen, exported: true)
            }
            try smokeCheck(records.count == 10 && Set(records.map(\.id)).count == 10, "十张独立贴图")
            try smokeCheck(records.allSatisfy { $0.panel?.level == .floating && $0.panel?.canBecomeKey == false }, "非激活浮动面板")
            guard let first = records.first else { throw SmokeFailure(message: "缺少贴图") }
            handle(.passThrough, record: first)
            try smokeCheck(first.panel?.ignoresMouseEvents == true, "鼠标穿透")
            clearAllPassThrough()
            try smokeCheck(records.allSatisfy { !$0.clickThrough }, "解除全部穿透")
            setHidden(first, true)
            protectPrivacy(reason: "合成休眠事件")
            try smokeCheck(records.allSatisfy { $0.panel?.isVisible == false }, "隐私保护隐藏全部面板")
            try await checkProtectedActions(first: first)
            try smokeCheck(first.hidden && first.panel?.isVisible == false, "恢复保留用户隐藏状态")
            toggleAll()
            try smokeCheck(records.allSatisfy(\.hidden), "全部隐藏")
            toggleAll()
            try smokeCheck(records.allSatisfy { !$0.hidden }, "全部显示")
            for record in records { await close(record) }
            for _ in 0..<100 {
                let id = try await budget.reserve(bytes: 128 * 96 * 8, kind: .screenshot)
                makeStaticPin(image, logicalSize: CGSize(width: 128, height: 96), reservation: id, screen: screen, exported: true)
                if let record = records.first { await close(record) }
            }
            let usage = await budget.snapshot()
            try smokeCheck(records.isEmpty && usage.pins == 0 && usage.bytes == 0, "100 次创建关闭后预算清空")
            let renderer = try MirrorRenderer(outputSize: CGSize(width: 64, height: 64))
            let sink = MirrorFrameSink()
            renderer.sink = sink
            var pixelBuffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                              kCVPixelBufferIOSurfacePropertiesKey: [:]]
            let result = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
            guard result == kCVReturnSuccess, let pixelBuffer else { throw SmokeFailure(message: "无法创建合成帧") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let address = CVPixelBufferGetBaseAddress(pixelBuffer) { memset(address, 255, CVPixelBufferGetDataSize(pixelBuffer)) }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            _ = sink.mailbox.offer(CapturedFrame(buffer: pixelBuffer, pixelRect: CGRect(x: 0, y: 0, width: 64, height: 64), date: Date()))
            renderer.consumeLatest()
            for _ in 0..<100 where !renderer.hasFrame { try await Task.sleep(for: .milliseconds(20)) }
            try smokeCheck(renderer.hasFrame, "Metal 合成帧渲染")
            let snapshot = try renderer.snapshot()
            try smokeCheck(snapshot.width == 64 && snapshot.height == 64, "镜像纹理转静态图")
            renderer.invalidate(clearFrame: true)
            await renderer.drain()
            try smokeCheck(!renderer.hasFrame, "清除镜像帧")
            try smokeCheck(!WindowPinPolicy.isSupported, "真实原窗口置顶路径关闭，不运行伪成功后端")
            picker.shutdown()
            print("应用冒烟检查通过：贴图、穿透、隐私确认与取消、代次保护、资源循环、Metal 合成帧、能力边界。未申请权限、未捕获用户屏幕或读取剪贴板。")
            NSApp.terminate(nil)
        } catch {
            print("应用冒烟检查失败：\(error)")
            Foundation.exit(1)
        }
    }
    private func smokeCheck(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SmokeFailure(message: name) }
        print("通过：\(name)")
    }

    private func checkProtectedActions(first: PinRecord) async throws {
        let protectedGeneration = gate.generation
        var prompts = 0
        let cancelled = prepareForUserAction { prompts += 1; return false }
        try smokeCheck(!cancelled && prompts == 1 && privacyHidden && notice != nil,
                       "功能入口被保护时有反馈，取消不恢复")
        var ran = false
        perform { _ in ran = true }
        try smokeCheck(!ran && !isBusy && operationTask == nil, "未确认时不启动内容任务")
        try smokeCheck(records.allSatisfy { $0.panel?.isVisible == false } && first.image != nil,
                       "取消保留隐藏内容且不丢弃图像")

        selectWindowPin()
        try smokeCheck(notice == WindowPinPolicy.title && privacyHidden && gate.generation == protectedGeneration,
                       "能力说明不被隐私状态静默吞掉，也不恢复内容或申请权限")
        isBusy = true
        let busy = prepareForUserAction { prompts += 1; return true }
        try smokeCheck(!busy && prompts == 1 && notice?.contains("已有贴图不需要关闭") == true,
                       "忙碌时给出原因，不要求解除全部置顶")
        isBusy = false

        let stale = prepareForUserAction {
            self.protectPrivacy(reason: "确认期间的新保护事件")
            return true
        }
        try smokeCheck(!stale && privacyHidden && gate.protected, "旧确认不能解除新的保护事件")
        try smokeCheck(privacyReason == "确认期间的新保护事件", "界面可显示保护触发原因")
        var nestedPrompt = false
        let accepted = prepareForUserAction {
            _ = self.prepareForUserAction { nestedPrompt = true; return true }
            return true
        }
        try smokeCheck(accepted && !nestedPrompt && !privacyHidden && !gate.protected,
                       "确认后直接继续，不重复嵌套恢复弹窗")
        try smokeCheck(!gate.accepts(protectedGeneration), "恢复不会复活保护前的任务")
        try smokeCheck(first.hidden && first.panel?.isVisible == false && records.dropFirst().contains { $0.panel?.isVisible == true },
                       "恢复只显示原先可见内容，不解除手动隐藏")
        perform { token in ran = self.gate.accepts(token) }
        await operationTask?.value
        try smokeCheck(ran && !isBusy && operationTask == nil, "恢复后本次任务正常执行并释放忙碌状态")
        terminating = true
        let terminatingAllowed = prepareForUserAction { true }
        terminating = false
        try smokeCheck(!terminatingAllowed, "退出阶段拒绝新增内容任务")
    }
}

private struct SmokeFailure: Error { let message: String }
