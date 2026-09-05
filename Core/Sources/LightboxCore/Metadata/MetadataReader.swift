import Foundation
import ImageIO

/// Reads image metadata with ImageIO, in-process.
///
/// ImageIO rather than exiftool: indexing 50k files must not fork 50k
/// subprocesses, and ImageIO covers every format this app indexes for reading.
/// exiftool appears only on the write path, in phase 2.
public struct MetadataReader: MetadataReading {
    public init() {}

    public func read(_ url: URL) throws -> ImageMetadata {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MetadataError.unreadable
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary)
                  as? [CFString: Any],
              let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int
        else {
            throw MetadataError.notAnImage
        }

        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifOffsetTimeDigitized] as? String

        let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String

        return ImageMetadata(
            width: width,
            height: height,
            captureTime: stamp.flatMap { Self.parseEXIFDate($0, offset: offset) },
            captureOffset: offset,
            cameraMake: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed,
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed,
            orientation: raw[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// Parses EXIF's `yyyy:MM:dd HH:mm:ss`.
    ///
    /// The format carries no zone. When `OffsetTimeOriginal` is present it is
    /// authoritative; otherwise the timestamp is interpreted as UTC. UTC rather
    /// than the machine's local zone deliberately: the local zone would make
    /// the same file sort differently depending on where it was indexed, which
    /// is a silent, invisible bug. Phase 2's editor makes the zone explicit.
    static func parseEXIFDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(Self.timeZone(fromOffset:)) ?? TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
    }

    /// Converts an EXIF offset string such as `-05:00` into a time zone.
    static func timeZone(fromOffset text: String) -> TimeZone? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6 else { return nil }
        let sign: Int
        switch trimmed.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let body = trimmed.dropFirst().split(separator: ":")
        guard body.count == 2, let hours = Int(body[0]), let minutes = Int(body[1]) else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension String {
    /// EXIF strings are frequently space- or NUL-padded by the writing device.
    var trimmed: String? {
        let cleaned = trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\0")))
        return cleaned.isEmpty ? nil : cleaned
    }
}
