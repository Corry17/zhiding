import Foundation
import CoreGraphics

public enum ZhidingError: Error, LocalizedError, Equatable {
    case invalidImage, imageTooLarge, budgetExceeded, pinLimit, mirrorLimit
    case invalidGeometry, cancelled, unsupportedImage, captureFailed, exportFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "图片损坏或无法解码。"
        case .imageTooLarge: return "图片超过 32 MP 或 50 MiB 限制。"
        case .budgetExceeded: return "图像内存超过预算，已有内容未改变。请关闭部分内容后重试。"
        case .pinLimit: return "已达到 20 张贴图上限，隐藏贴图也占用名额。"
        case .mirrorLimit: return "已达到 3 个镜像上限，已停止的镜像也占用名额。"
        case .invalidGeometry: return "屏幕尺寸或选区无效，请重新选择。"
        case .cancelled: return "操作已取消。"
        case .unsupportedImage: return "请选择 PNG/JPEG，或复制 PNG/TIFF 图片后重试。"
        case .captureFailed: return "无法捕获所选内容，请检查系统权限或重新选择。"
        case .exportFailed: return "图片未保存，当前贴图仍保留。"
        }
    }
}

public enum Limits {
    public static let pins = 20
    public static let mirrors = 3
    public static let pixels = 32_000_000
    public static let encodedBytes = 50 * 1024 * 1024
    public static let memoryBytes = 512 * 1024 * 1024
    public static let mirrorPixels = 1920 * 1080

    public static func surfaceBytes(width: Int, height: Int, copies: Int = 1) throws -> Int {
        guard width > 0, height > 0, copies > 0 else { throw ZhidingError.invalidGeometry }
        let (row, overflow1) = width.multipliedReportingOverflow(by: 4)
        let (padded, overflow2) = row.addingReportingOverflow(255)
        guard !overflow1, !overflow2 else { throw ZhidingError.imageTooLarge }
        let (size, overflow3) = ((padded / 256) * 256).multipliedReportingOverflow(by: height)
        let (total, overflow4) = size.multipliedReportingOverflow(by: copies)
        guard !overflow3, !overflow4, total <= memoryBytes else { throw ZhidingError.budgetExceeded }
        return total
    }

    public static func validateImage(width: Int, height: Int, bytes: Int) throws {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, bytes >= 0 else { throw ZhidingError.invalidImage }
        guard !overflow, count <= pixels, bytes <= encodedBytes else { throw ZhidingError.imageTooLarge }
    }
}

public enum Geometry {
    public static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    public static func pixelCrop(selection: CGRect, logicalSize: CGSize, pixelSize: CGSize) throws -> CGRect {
        guard valid(logicalSize), valid(pixelSize),
              [selection.origin.x, selection.origin.y, selection.width, selection.height].allSatisfy(\.isFinite)
        else { throw ZhidingError.invalidGeometry }
        let rect = selection.standardized.intersection(CGRect(origin: .zero, size: logicalSize))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { throw ZhidingError.invalidGeometry }
        let sx = pixelSize.width / logicalSize.width
        let sy = pixelSize.height / logicalSize.height
        let x = floor(rect.minX * sx), y = floor(rect.minY * sy)
        let result = CGRect(x: x, y: y, width: ceil(rect.maxX * sx) - x, height: ceil(rect.maxY * sy) - y)
            .intersection(CGRect(origin: .zero, size: pixelSize))
        guard valid(result.size) else { throw ZhidingError.invalidGeometry }
        return result
    }

    public static func fit(_ size: CGSize, inside bounds: CGSize, upscale: Bool = false) -> CGSize {
        guard valid(size), valid(bounds) else { return CGSize(width: 160, height: 100) }
        let scale = min(upscale ? CGFloat.greatestFiniteMagnitude : 1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    public static func mirrorOutput(_ nativeSize: CGSize) throws -> CGSize {
        guard valid(nativeSize), nativeSize.width <= 1_000_000, nativeSize.height <= 1_000_000 else {
            throw ZhidingError.invalidGeometry
        }
        let scale = min(1, sqrt(CGFloat(Limits.mirrorPixels) / (nativeSize.width * nativeSize.height)),
                        4096 / nativeSize.width, 4096 / nativeSize.height)
        let size = CGSize(width: floor(nativeSize.width * scale), height: floor(nativeSize.height * scale))
        guard valid(size) else { throw ZhidingError.invalidGeometry }
        return size
    }

    public static func constrain(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let size = fit(frame.size, inside: visible.size)
        return CGRect(x: max(visible.minX, min(frame.minX, visible.maxX - size.width)),
                      y: max(visible.minY, min(frame.minY, visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    // SDK 定义 contentRect 为表面内的点坐标，scaleFactor 将其转换为像素。
    public static func framePixelRect(contentRect: CGRect, scaleFactor: CGFloat, surface: CGSize) throws -> CGRect {
        guard scaleFactor.isFinite, (1...4).contains(scaleFactor), valid(surface),
              [contentRect.minX, contentRect.minY, contentRect.width, contentRect.height].allSatisfy(\.isFinite),
              contentRect.minX >= 0, contentRect.minY >= 0, valid(contentRect.size) else {
            throw ZhidingError.invalidGeometry
        }
        let result = contentRect.applying(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)).integral
        guard result.maxX <= surface.width + 1, result.maxY <= surface.height + 1 else {
            throw ZhidingError.invalidGeometry
        }
        return result.intersection(CGRect(origin: .zero, size: surface))
    }
}
