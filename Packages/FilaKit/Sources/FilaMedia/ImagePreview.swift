import CoreGraphics
import FilaFormats
import Foundation
import ImageIO

/// A first-frame preview whose decoded raster has a fixed pixel ceiling.
/// File-size checks alone cannot bound a compressed image's decoded allocation.
public enum ImagePreview {
    /// A well-formed image over the pixel ceiling. Its own error, because
    /// "too large to preview" and "not a picture" are different answers, and
    /// a valid panorama reported as an unsupported format reads as a broken file.
    public struct TooLarge: LocalizedError, Sendable, Hashable {
        public var width: Int64
        public var height: Int64

        public var errorDescription: String? {
            String(
                localized: "This image is too large to preview (\(width) × \(height) pixels). Open it as Hex to see its contents.",
                bundle: .module,
            )
        }
    }

    public static func make(data: Data) -> CGImage? {
        try? decode(data: data)
    }

    /// `make`, saying so when the image is too large to decode. Nil still
    /// means the bytes are not a picture ImageIO can read.
    public static func decode(data: Data) throws -> CGImage? {
        guard data.count <= PreviewLimits.fileByteCount,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary,
              ),
              case let (width, height)? = pixelSize(source)
        else { return nil }
        guard fits(width: width, height: height) else { throw TooLarge(width: width, height: height) }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: PreviewLimits.imagePixelSize,
        ] as CFDictionary)
    }

    static func hasSupportedDimensions(_ source: CGImageSource) -> Bool {
        guard case let (width, height)? = pixelSize(source) else { return false }
        return fits(width: width, height: height)
    }

    /// Whether a raster of this size may be decoded at all: a codec can
    /// allocate the whole source raster before it scales anything down.
    static func fits(width: Int64, height: Int64) -> Bool {
        width > 0 && height > 0 && width <= 32768 && height <= 32768 && width <= 64_000_000 / height
    }

    /// The first frame's declared size, or nil when it declares none.
    private static func pixelSize(_ source: CGImageSource) -> (width: Int64, height: Int64)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
