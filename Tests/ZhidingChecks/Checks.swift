import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZhidingCore

@main
struct Checks {
    static var passed = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw Failure(name: name) }
        passed += 1
        print("通过：\(name)")
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { passed += 1; print("通过：\(name)"); return }
        throw Failure(name: name)
    }
    static func main() async {
        do {
            try geometry()
            try images()
            try await resources()
            try concurrency()
            try windowPins()
            print("共 \(passed) 项逻辑检查通过；不等于系统权限、锁屏或真实捕获已验收。")
        } catch { print("检查失败：\(error)"); exit(1) }
    }

    static func geometry() throws {
        let rect = try Geometry.pixelCrop(selection: CGRect(x: 100, y: 100, width: 300, height: 100),
                                          logicalSize: CGSize(width: 1280, height: 720), pixelSize: CGSize(width: 2560, height: 1440))
        try check(rect == CGRect(x: 200, y: 200, width: 600, height: 200), "Retina 坐标转换")
        let clipped = try Geometry.pixelCrop(selection: CGRect(x: -10, y: -10, width: 30, height: 30),
                                             logicalSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 100, height: 100))
        try check(clipped == CGRect(x: 0, y: 0, width: 20, height: 20), "选区裁剪到屏幕边界")
        let fractional = try Geometry.pixelCrop(selection: CGRect(x: 0.1, y: 0.2, width: 3.1, height: 3.1),
                                                logicalSize: CGSize(width: 10, height: 10), pixelSize: CGSize(width: 15, height: 20))
        try check(fractional == CGRect(x: 0, y: 0, width: 5, height: 7), "分数比例向外舍入")
        try rejects("空选区拒绝") { _ = try Geometry.pixelCrop(selection: .zero, logicalSize: CGSize(width: 10, height: 10), pixelSize: CGSize(width: 20, height: 20)) }
        try rejects("非有限尺寸拒绝") { _ = try Geometry.mirrorOutput(CGSize(width: CGFloat.infinity, height: 10)) }
        let output = try Geometry.mirrorOutput(CGSize(width: 3840, height: 2160))
        try check(output == CGSize(width: 1920, height: 1080), "镜像像素预算")
        let portrait = try Geometry.mirrorOutput(CGSize(width: 2160, height: 3840))
        try check(portrait.width * portrait.height <= CGFloat(Limits.mirrorPixels), "竖屏保持像素预算")
        let long = try Geometry.mirrorOutput(CGSize(width: 20000, height: 100))
        try check(long.width <= 4096, "极长窗口纹理上限")
        let visible = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let constrained = Geometry.constrain(CGRect(x: -2000, y: -50, width: 400, height: 300), to: visible)
        try check(visible.contains(constrained), "负坐标屏幕窗口恢复")
        try check(Geometry.fit(CGSize(width: 20, height: 10), inside: CGSize(width: 640, height: 480)) == CGSize(width: 20, height: 10), "小图不放大")
        let frame = try Geometry.framePixelRect(contentRect: CGRect(x: 0, y: 0, width: 100, height: 50), scaleFactor: 2, surface: CGSize(width: 200, height: 100))
        try check(frame == CGRect(x: 0, y: 0, width: 200, height: 100), "帧元数据单位适配")
        try rejects("帧越界拒绝") { _ = try Geometry.framePixelRect(contentRect: CGRect(x: 48, y: 0, width: 100, height: 50), scaleFactor: 2, surface: CGSize(width: 200, height: 100)) }
        try rejects("乘法溢出拒绝") { _ = try Limits.surfaceBytes(width: Int.max, height: 2) }
        try rejects("超 32 MP 拒绝") { try Limits.validateImage(width: 10000, height: 10000, bytes: 10) }
        try rejects("超 50 MiB 拒绝") { try Limits.validateImage(width: 1, height: 1, bytes: Limits.encodedBytes + 1) }
    }

    static func images() throws {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = context.makeImage()!
        let data = try ImageCodec.png(image)
        let info = try ImageCodec.inspect(data)
        try check(info.width == 40 && info.height == 20 && info.frameCount == 1, "PNG 编码与元数据读取")
        let decoded = try ImageCodec.decode(data)
        try check(decoded.width == 40 && decoded.height == 20, "PNG 解码保留尺寸")
        try check(decoded.colorSpace?.name == CGColorSpace.sRGB, "图像统一 sRGB")
        try check(decoded.alphaInfo == .premultipliedLast, "透明度通道保留")
        let crop = try ImageCodec.independentCopy(decoded, crop: CGRect(x: 10, y: 2, width: 12, height: 8))
        try check(crop.width == 12 && crop.height == 8, "裁剪生成独立尺寸缓冲")
        try rejects("损坏文件拒绝") { _ = try ImageCodec.decode(Data("not an image".utf8)) }
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let rotated = try ImageCodec.decode(jpeg as Data)
        try check(rotated.width == 20 && rotated.height == 40, "JPEG 方向规范化")
        let tiff = NSMutableData()
        let tiffDestination = CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(tiffDestination, image, nil)
        CGImageDestinationFinalize(tiffDestination)
        try rejects("本地导入不接受 TIFF") { _ = try ImageCodec.inspect(tiff as Data) }
        try check(try ImageCodec.inspect(tiff as Data, allowTIFF: true).width == 40, "剪贴板路径允许 TIFF")
    }

    static func resources() async throws {
        let budget = ResourceBudget()
        var ids: [UUID] = []
        for _ in 0..<20 { ids.append(try await budget.reserve(bytes: 100, kind: .screenshot)) }
        let first = await budget.snapshot()
        try check(first.pins == 20 && first.bytes == 2000, "贴图名额预留计数")
        do { _ = try await budget.reserve(bytes: 0, kind: .screenshot); throw Failure(name: "贴图上限") }
        catch ZhidingError.pinLimit { passed += 1 }
        for id in ids { await budget.release(id); await budget.release(id) }
        let empty = await budget.snapshot()
        try check(empty.bytes == 0 && empty.pins == 0, "释放幂等")
        let full = try await budget.reserve(bytes: Limits.memoryBytes)
        do { _ = try await budget.reserve(bytes: 1); throw Failure(name: "预算超额") }
        catch ZhidingError.budgetExceeded { passed += 1 }
        await budget.release(full)
        let limitBudget = ResourceBudget()
        let success = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 { group.addTask { (try? await limitBudget.reserve(bytes: 10, kind: .mirror)) != nil } }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        try check(success == 3, "并发镜像预留不超 3 个")
        let reservation = try await budget.reserve(bytes: 100)
        try await budget.resize(reservation, bytes: 200)
        let resized = await budget.snapshot()
        try check(resized.bytes == 200, "预算事务调整")
        do { try await budget.resize(reservation, bytes: Limits.memoryBytes + 1); throw Failure(name: "调整失败") }
        catch ZhidingError.budgetExceeded { passed += 1 }
        let unchanged = await budget.snapshot()
        try check(unchanged.bytes == 200, "预算调整失败保留原预留")
        await budget.release(reservation)
        do { try await budget.resize(reservation, bytes: 10); throw Failure(name: "已取消预留") }
        catch ZhidingError.cancelled { passed += 1 }
    }

    static func concurrency() throws {
        let mailbox = LatestMailbox<Int>()
        try check(mailbox.offer(1), "首帧触发通知")
        try check(!mailbox.offer(2), "新帧覆盖但不重复调度")
        try check(mailbox.take() == 2, "仅消费最新帧")
        try check(mailbox.offer(3), "消费后可以重新调度")
        mailbox.invalidate()
        try check(mailbox.take() == nil && !mailbox.offer(4), "关闭后迟到帧拒绝")
        var gate = OperationGate()
        let first = gate.generation
        try check(gate.accepts(first), "当前代次有效")
        gate.protect()
        try check(!gate.accepts(first) && gate.protected, "保护使在途任务失效")
        gate.resume()
        try check(!gate.accepts(first) && gate.accepts(gate.generation), "恢复不复活旧任务")
    }

    static func windowPins() throws {
        try check(!WindowPinPolicy.isSupported, "原窗口置顶不能由只读属性伪装为可用")
        try check(WindowPinPolicy.explanation.contains("只读") && WindowPinPolicy.explanation.contains("不需要"), "明确能力限制且不诱导反复授权")
        try check(WindowPinPolicy.alternative.contains("不能在镜像里"), "镜像不冒充可操作的原窗口")
        try check(WindowPinPolicy.sandboxExplanation.contains("不等于"), "辅助功能授权与沙盒限制独立")
    }
}

struct Failure: Error { let name: String }
