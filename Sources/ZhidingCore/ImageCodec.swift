import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct ImageInfo: Sendable {
    public let width: Int
    public let height: Int
    public let frameCount: Int
}

public enum ImageCodec {
    public static func inspect(_ data: Data, allowTIFF: Bool = false) throws -> ImageInfo {
        guard data.count <= Limits.encodedBytes else { throw ZhidingError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { throw ZhidingError.invalidImage }
        let allowed = [UTType.png.identifier, UTType.jpeg.identifier] + (allowTIFF ? [UTType.tiff.identifier] : [])
        guard allowed.contains(type) else { throw ZhidingError.unsupportedImage }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ZhidingError.invalidImage }
        try Limits.validateImage(width: width, height: height, bytes: data.count)
        return ImageInfo(width: width, height: height, frameCount: CGImageSourceGetCount(source))
    }

    public static func decode(_ data: Data, allowTIFF: Bool = false) throws -> CGImage {
        let info = try inspect(data, allowTIFF: allowTIFF)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ZhidingError.invalidImage }
        return try independentCopy(image)
    }

    public static func independentCopy(_ image: CGImage, crop: CGRect? = nil) throws -> CGImage {
        let selected: CGImage
        if let crop {
            guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= CGFloat(image.width),
                  crop.maxY <= CGFloat(image.height), let result = image.cropping(to: crop) else {
                throw ZhidingError.invalidGeometry
            }
            selected = result
        } else { selected = image }
        try Limits.validateImage(width: selected.width, height: selected.height, bytes: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: selected.width, height: selected.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ZhidingError.invalidImage
        }
        context.draw(selected, in: CGRect(x: 0, y: 0, width: selected.width, height: selected.height))
        guard let copy = context.makeImage() else { throw ZhidingError.invalidImage }
        return copy
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ZhidingError.exportFailed
        }
        // 仅写入规范化像素，不透传来源文件的 EXIF、GPS 或文本元数据。
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ZhidingError.exportFailed }
        return data as Data
    }
}
