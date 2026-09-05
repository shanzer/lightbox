import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum Fixtures {
    enum Format {
        case jpeg, png, heic, tiff
        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .tiff: .tiff
            }
        }
        var ext: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .heic: "heic"
            case .tiff: "tiff"
            }
        }
    }

    /// A deterministic gradient, so two calls with the same size produce
    /// byte-identical pixels and hash tests are stable.
    static func image(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: Double((x &+ seed) % 256) / 255.0,
                                 green: Double((y &+ seed) % 256) / 255.0,
                                 blue: Double((x &* y &+ seed) % 256) / 255.0,
                                 alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func writeImage(to url: URL, format: Format = .jpeg,
                           width: Int = 64, height: Int = 48, seed: Int = 0,
                           captureTime: String? = "2019:03:04 10:11:12",
                           offset: String? = "-05:00",
                           make: String? = "TestCam", model: String? = "T1",
                           orientation: Int = 1) throws -> URL {
        var exif: [CFString: Any] = [:]
        if let captureTime { exif[kCGImagePropertyExifDateTimeOriginal] = captureTime }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }

        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image(width: width, height: height, seed: seed),
                                   props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let name): "fixture \(name) is missing from the test bundle"
        }
    }
}

extension Fixtures {
    /// A checked-in fixture file, copied into the test bundle by
    /// `resources: [.copy("Fixtures")]`.
    ///
    /// Needed for formats ImageIO cannot write: `CGImageDestinationCreateWithURL`
    /// returns nil for `org.webmproject.webp`, so a WebP cannot be generated the
    /// way `writeImage` generates the others.
    static func url(_ name: String) throws -> URL {
        // `.copy` preserves the directory, so the resource is addressed by the
        // path within it rather than by bare name; the flattened lookup is a
        // fallback in case a future manifest switches to `.process`.
        if let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: nil) {
            return url
        }
        throw FixtureError.missing(name)
    }
}
