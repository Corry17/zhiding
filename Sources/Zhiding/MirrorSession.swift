import AppKit
import ScreenCaptureKit
import ZhidingCore

@MainActor
final class MirrorSession: NSObject {
    let stream: SCStream
    let sink = MirrorFrameSink()
    private let config: SCStreamConfiguration
    private let captureQueue = DispatchQueue(label: "app.zhiding.capture", qos: .userInteractive)
    private weak var renderer: MirrorRenderer?
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Bool, Never>?
    private var updateTask: Task<Void, Never>?
    private var desiredHidden = false
    private var accepting = true
    private var systemEnded = false
    private(set) var isCapturing = false
    var requiresPicker: Bool { accepting || isCapturing }
    var onState: ((String) -> Void)?
    var onEnded: (() -> Void)?

    private init(filter: SCContentFilter, config: SCStreamConfiguration, renderer: MirrorRenderer, bridge: StreamDelegateBridge) {
        self.config = config
        stream = SCStream(filter: filter, configuration: config, delegate: bridge)
        self.renderer = renderer
        super.init()
        delegateBridge = bridge
        bridge.owner = self
        renderer.sink = sink
        sink.onReady = { [weak renderer] in
            DispatchQueue.main.async { renderer?.consumeLatest() }
        }
        sink.onState = { [weak self] message, terminal, alreadyStopped in
            DispatchQueue.main.async {
                guard let self else { return }
                if alreadyStopped { self.endFromSystem(alreadyStopped: true); return }
                guard self.accepting else { return }
                self.onState?(message)
                if terminal { self.endFromSystem() }
            }
        }
        renderer.onFailure = { [weak self] in self?.endFromSystem() }
    }
    private var delegateBridge: StreamDelegateBridge?

    static func make(filter: SCContentFilter, output: CGSize, renderer: MirrorRenderer) -> MirrorSession {
        let config = SCStreamConfiguration()
        config.width = Int(output.width); config.height = Int(output.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.capturesAudio = false
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.streamName = "置顶 · 仅查看"
        return MirrorSession(filter: filter, config: config, renderer: renderer, bridge: StreamDelegateBridge())
    }

    func start() async throws {
        guard accepting else { throw ZhidingError.cancelled }
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
        let task = Task { try await stream.startCapture() }
        startTask = task
        try await task.value
        if accepting {
            isCapturing = true
            if desiredHidden { setHidden(true) }
        }
    }

    func setHidden(_ hidden: Bool) {
        desiredHidden = hidden
        guard updateTask == nil, accepting, startTask != nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updateTask = nil }
            do {
                _ = await self.startTask?.result
                while self.accepting {
                    let applied = self.desiredHidden
                    self.config.minimumFrameInterval = CMTime(value: 1, timescale: applied ? 1 : 30)
                    try await self.stream.updateConfiguration(self.config)
                    if self.desiredHidden == applied { break }
                }
            } catch { self.endFromSystem() }
        }
    }

    func stop(clearFrame: Bool) async -> Bool {
        accepting = false
        sink.mailbox.invalidate()
        renderer?.invalidate(clearFrame: clearFrame)
        if let stopTask {
            let result = await stopTask.value
            if result || systemEnded { return await finishStop() }
            return false
        }
        let task = Task { [self] in
            let result = await startTask?.result
            _ = await updateTask?.value
            let didStart: Bool
            if case .success = result { didStart = true } else { didStart = false }
            do {
                if didStart && !systemEnded { try await stream.stopCapture() }
                return await finishStop()
            } catch {
                if systemEnded { return await finishStop() }
                onState?("停止失败，请退出应用结束捕获")
                return false
            }
        }
        stopTask = task
        return await task.value
    }

    private func finishStop() async -> Bool {
        try? stream.removeStreamOutput(sink, type: .screen)
        await renderer?.drain()
        isCapturing = false
        return true
    }

    fileprivate func endFromSystem(alreadyStopped: Bool = false) {
        systemEnded = systemEnded || alreadyStopped
        if alreadyStopped { isCapturing = false }
        guard accepting else {
            if alreadyStopped { onEnded?() }
            return
        }
        accepting = false
        renderer?.invalidate(clearFrame: true)
        onState?("共享已停止，画面已清除")
        Task { [weak self] in
            guard let self else { return }
            if await self.stop(clearFrame: true) { self.onEnded?() }
        }
    }
}

private final class StreamDelegateBridge: NSObject, SCStreamDelegate {
    weak var owner: MirrorSession?
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.owner?.endFromSystem(alreadyStopped: true) }
    }
}
