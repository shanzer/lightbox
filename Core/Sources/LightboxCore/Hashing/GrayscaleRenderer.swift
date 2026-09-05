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
///
/// This pipeline is where lightbox and photolib diverge: the hash function is
/// bit-exact between the tools, the file-to-grid reduction is not. See the
/// `PerceptualHash` doc comment for the measured cross-tool spread.
public struct GrayscaleRenderer: GrayscaleRendering {
    public static let size = 32

    /// Part of the hash definition, not a speed knob: these resampled pixels
    /// feed the DCT directly, so changing this changes hashes. Measured over
    /// 36 real photos, moving from 256 to a full-size intermediate changed 20
    /// of 36 hashes (exact matches against photolib 16/36 vs 26/36, mean
    /// divergence 1.22 vs 0.67 bits -- both far under the matching threshold
    /// of 12). 256 is kept because full-decoding a 48-megapixel RAW on the
    /// first pass over a 50,000-image library is a real cost for a fraction
    /// of a bit. Do not tune: bumping it "for quality" silently invalidates
    /// every cached hash. (`ThumbnailFromImageAlways` below forces a full
    /// decode at this size -- embedded previews are deliberately not used.)
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
            // A CGContext allocation failure is an internal/OOM condition, not
            // malformed input; .notAnImage is reused anyway to keep the error
            // surface small, since callers treat both the same way: no hash
            // can be produced for this file.
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
