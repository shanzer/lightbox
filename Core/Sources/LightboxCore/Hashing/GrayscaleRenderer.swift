import Foundation
import CoreGraphics
import ImageIO

public protocol GrayscaleRendering: Sendable {
    func gray32(from url: URL) throws -> [UInt8]
}

/// Reduces an image to the 32x32 luminance grid the perceptual hash consumes.
///
/// Not derived from the QuickLook thumbnail: QuickLook fits to aspect and may
/// pad, and for RAW it can return the camera's embedded preview rather than a
/// render of the image data. Either would make the hash describe QuickLook's
/// behaviour instead of the image.
public struct GrayscaleRenderer: GrayscaleRendering {
    public static let size = 32

    /// An intermediate downsample. Going straight from a 48-megapixel original
    /// to 32x32 in one step is both slow and aliased; ImageIO produces this
    /// step cheaply from the embedded preview when one exists.
    private static let intermediateMaxPixels = 256

    public init() {}

    public func gray32(from url: URL) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.notAnImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.intermediateMaxPixels,
            // Apply the EXIF orientation: the hash should describe the image as
            // displayed, so a photo and its correctly-rotated export match.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MetadataError.notAnImage
        }

        let size = Self.size
        let bytesPerRow = size * 4
        var raster = [UInt8](repeating: 0, count: bytesPerRow * size)

        try raster.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw MetadataError.notAnImage }
            context.interpolationQuality = .high
            // Squashed to a square, aspect deliberately not preserved: this
            // matches photolib's `sips -z 32 32`, so a 16:9 and a 4:3 crop of
            // the same scene remain comparable.
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        var gray = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let at = i * 4
            let luminance = 0.2126 * Double(raster[at])
                          + 0.7152 * Double(raster[at + 1])
                          + 0.0722 * Double(raster[at + 2])
            gray[i] = UInt8(min(255, max(0, luminance.rounded())))
        }
        return gray
    }
}
