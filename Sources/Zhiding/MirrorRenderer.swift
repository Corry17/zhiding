import AppKit
import MetalKit
import CoreImage
import ScreenCaptureKit
import ZhidingCore

// 接收后只读；由强引用保证像素缓冲在 GPU 完成前不会归还捕获池。
struct CapturedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let pixelRect: CGRect
    let date: Date
}

// 纹理操作均提交至同一串行 Metal 队列，主线程只在完成后发布引用。
private struct GPUFrameLease: @unchecked Sendable {
    let frame: CapturedFrame
    let texture: MTLTexture
}

final class MirrorFrameSink: NSObject, SCStreamOutput {
    let mailbox = LatestMailbox<CapturedFrame>()
    var onReady: (() -> Void)?
    var onState: ((String, Bool, Bool) -> Void)?
    private var invalidFrames = 0
    private var previousState: String?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let raw = metadata[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .blank: report("共享已停止，画面已清除", terminal: true); return
        case .stopped: report("共享已停止，画面已清除", terminal: true, alreadyStopped: true); return
        case .suspended: report("暂停更新", terminal: false); return
        case .idle, .started: return
        case .complete: break
        @unknown default: return
        }
        do {
            let dictionaryRect = (metadata[.contentRect] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            guard let buffer = sampleBuffer.imageBuffer,
                  let contentRect = (metadata[.contentRect] as? CGRect) ?? dictionaryRect,
                  let factor = metadata[.scaleFactor] as? NSNumber else { throw ZhidingError.invalidGeometry }
            let rect = try Geometry.framePixelRect(contentRect: contentRect, scaleFactor: CGFloat(factor.doubleValue),
                                                  surface: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            invalidFrames = 0
            previousState = nil
            if mailbox.offer(CapturedFrame(buffer: buffer, pixelRect: rect, date: Date())) { onReady?() }
        } catch {
            invalidFrames += 1
            if invalidFrames >= 5 { report("帧尺寸异常，请重新选择", terminal: true) }
        }
    }
    private func report(_ state: String, terminal: Bool, alreadyStopped: Bool = false) {
        guard state != previousState || alreadyStopped else { return }
        previousState = state
        if terminal { mailbox.invalidate() }
        onState?(state, terminal, alreadyStopped)
    }
}

@MainActor
final class MirrorRenderer: MTKView, MTKViewDelegate {
    private let context: CIContext
    private let commands: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var textures: [MTLTexture] = []
    private var currentIndex = 0
    private var lastTexture: MTLTexture?
    private var active = true
    private var busy = false
    private var epoch = UUID()
    weak var sink: MirrorFrameSink?
    var onFrame: ((Date) -> Void)?
    var onFailure: (() -> Void)?
    var hasFrame: Bool { lastTexture != nil }

    init(outputSize: CGSize) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ZhidingError.captureFailed
        }
        commands = queue
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = false
        drawableSize = outputSize
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        delegate = self
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: Int(outputSize.width), height: Int(outputSize.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        for _ in 0..<2 {
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw ZhidingError.budgetExceeded }
            textures.append(texture)
        }
    }
    required init(coder: NSCoder) { fatalError("不支持归档加载") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func consumeLatest() {
        guard active, !busy, let frame = sink?.mailbox.take(), let command = commands.makeCommandBuffer() else { return }
        busy = true
        let token = epoch
        let target = textures[currentIndex]
        currentIndex = (currentIndex + 1) % textures.count
        let input = CIImage(cvPixelBuffer: frame.buffer)
        let crop = CGRect(x: frame.pixelRect.minX, y: input.extent.height - frame.pixelRect.maxY,
                          width: frame.pixelRect.width, height: frame.pixelRect.height)
        let cropped = input.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let fitted = Geometry.fit(crop.size, inside: drawableSize, upscale: true)
        let image = cropped.transformed(by: CGAffineTransform(scaleX: fitted.width / crop.width, y: fitted.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: (drawableSize.width - fitted.width) / 2,
                                              y: (drawableSize.height - fitted.height) / 2))
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let composed = image.composited(over: CIImage(color: .clear).cropped(to: bounds))
        context.render(composed, to: target, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        let lease = GPUFrameLease(frame: frame, texture: target)
        command.addCompletedHandler { [weak self, lease] buffer in
            // 捕获缓冲保持到 GPU 完成；最后画面保存在独立纹理中。
            withExtendedLifetime(lease.frame.buffer) {}
            let succeeded = buffer.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.active, self.epoch == token else { return }
                guard succeeded else { self.onFailure?(); return }
                self.lastTexture = lease.texture
                self.needsDisplay = true
                self.onFrame?(lease.frame.date)
                self.consumeLatest()
            }
        }
        command.commit()
    }

    func draw(in view: MTKView) {
        guard let texture = lastTexture, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(),
              let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else { return }
        context.render(image, to: drawable.texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: drawableSize), colorSpace: colorSpace)
        command.present(drawable)
        command.commit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func snapshot() throws -> CGImage {
        guard let texture = lastTexture else { throw ZhidingError.captureFailed }
        let barrier = commands.makeCommandBuffer()
        barrier?.commit(); barrier?.waitUntilCompleted()
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]),
              let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ZhidingError.captureFailed
        }
        return result
    }

    func invalidate(clearFrame: Bool) {
        active = false
        epoch = UUID()
        sink?.mailbox.invalidate()
        if clearFrame {
            lastTexture = nil
            isHidden = true
        }
    }

    func drain() async {
        guard let barrier = commands.makeCommandBuffer() else { return }
        await withCheckedContinuation { continuation in
            barrier.addCompletedHandler { _ in continuation.resume() }
            barrier.commit()
        }
        if lastTexture == nil { textures.removeAll() }
    }
}
