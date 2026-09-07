import Foundation
import ImageIO

/// A second, independent reader for the write tests.
///
/// The point of the MWG mapping is that *different* readers agree about a
/// field. A test that only asks exiftool what exiftool wrote proves that
/// exiftool is self-consistent and nothing else, so every round-trip assertion
/// is made twice: once through exiftool's JSON, and once through ImageIO here —
/// which is also the reader the rest of this app actually uses.
enum ImageIOProbe {
    static func properties(_ url: URL) -> [CFString: Any] {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary)
                  as? [CFString: Any]
        else { return [:] }
        return raw
    }

    static func dictionary(_ url: URL, _ key: CFString) -> [CFString: Any] {
        properties(url)[key] as? [CFString: Any] ?? [:]
    }

    static func tiff(_ url: URL) -> [CFString: Any] {
        dictionary(url, kCGImagePropertyTIFFDictionary)
    }

    static func exif(_ url: URL) -> [CFString: Any] {
        dictionary(url, kCGImagePropertyExifDictionary)
    }

    static func iptc(_ url: URL) -> [CFString: Any] {
        dictionary(url, kCGImagePropertyIPTCDictionary)
    }

    static func gps(_ url: URL) -> [CFString: Any] {
        dictionary(url, kCGImagePropertyGPSDictionary)
    }
}
