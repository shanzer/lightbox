import Foundation

extension MetadataWriter {
    /// What one edit turns into: the arguments exiftool is given, and the tags
    /// that are read back afterwards to prove it took.
    ///
    /// The two halves are built together on purpose. A verification list
    /// derived separately from the write list is a list that drifts, and a
    /// verification step that checks the wrong tag is worse than none — it
    /// reports success for a write that did not happen.
    struct Plan {
        var writeArguments: [String]
        var expectations: [Expectation]
    }

    struct Expectation: Equatable {
        /// The `-TAG` argument that asks for this value back.
        var argument: String
        /// The key it comes back under in `exiftool -j -G1` output.
        var key: String
        var expected: Expected
    }

    enum Expected: Equatable {
        case text(String)
        case list([String])
        case integer(Int)
        /// Compared with a tolerance: EXIF stores GPS as three rationals, so a
        /// decimal degree does not survive as an exact `Double`.
        case number(Double, tolerance: Double)
        /// The field was cleared, so the tag must not be there at all.
        case absent
    }

    static func plan(_ edit: MetadataEdit, target: WriteTarget,
                     options: WriteOptions) -> Plan {
        let toSidecar: Bool
        if case .sidecar = target { toSidecar = true } else { toSidecar = false }

        var arguments: [String] = []
        var expectations: [Expectation] = []

        // `-m` downgrades minor warnings so an odd but harmless container does
        // not abort the write; verification is what decides whether it worked.
        arguments.append("-m")
        if options.preserveModificationTime { arguments.append("-P") }
        if !toSidecar {
            // Keeps the Photoshop IPTC digest in step with the IPTC block MWG
            // just rewrote. Stale, it makes every later MWG reader announce
            // "IPTCDigest is not current" and quietly prefer XMP over IPTC.
            arguments.append("-IPTCDigest=new")
        }

        func scalar(_ tag: String, _ value: String?, key: String? = nil) {
            guard let value else { return }
            arguments.append("-\(tag)=\(value)")
            expectations.append(Expectation(argument: "-\(tag)", key: key ?? tag,
                                            expected: value.isEmpty ? .absent : .text(value)))
        }

        scalar("MWG:Description", edit.description)
        scalar("MWG:Creator", edit.artist)
        scalar("MWG:Copyright", edit.copyright)
        // Label has no MWG composite; the Metadata Working Group never defined
        // one, and XMP is the only family that carries it.
        scalar("XMP-xmp:Label", edit.label)

        if let keywords = edit.keywords {
            // Assigning replaces nothing — exiftool *appends* to a list tag —
            // so the list is cleared first. Order matters and is preserved.
            arguments.append("-MWG:Keywords=")
            for keyword in keywords { arguments.append("-MWG:Keywords=\(keyword)") }
            expectations.append(Expectation(
                argument: "-MWG:Keywords", key: "MWG:Keywords",
                expected: keywords.isEmpty ? .absent : .list(keywords)))
        }

        if let rating = edit.rating {
            arguments.append("-MWG:Rating=\(rating)")
            expectations.append(Expectation(argument: "-MWG:Rating", key: "MWG:Rating",
                                            expected: .integer(rating)))
        }

        if let capture = edit.captureTime, let offset = capture.offset,
           let zone = MetadataReader.timeZone(fromOffset: offset) {
            let stamp = exifTimestamp(capture, zone: zone)
            // Handed to MWG *with* the sub-seconds and the zone, so
            // XMP-photoshop:DateCreated and IPTC:TimeCreated carry them too;
            // EXIF:DateTimeOriginal has nowhere to put either, which is exactly
            // why the two EXIF companion tags below exist.
            arguments.append("-MWG:DateTimeOriginal=\(stamp)")
            expectations.append(Expectation(argument: "-MWG:DateTimeOriginal",
                                            key: "MWG:DateTimeOriginal",
                                            expected: .text(stamp)))
            if !toSidecar {
                arguments.append("-EXIF:OffsetTimeOriginal=\(offset)")
                arguments.append("-EXIF:SubSecTimeOriginal=\(capture.subSeconds ?? "")")
                expectations.append(Expectation(argument: "-ExifIFD:OffsetTimeOriginal",
                                                key: "ExifIFD:OffsetTimeOriginal",
                                                expected: .text(offset)))
                // Verified through the composite rather than through
                // SubSecTimeOriginal directly: `-n` renders that tag as a
                // number, so "025" would come back as 25 and compare unequal to
                // itself. The composite renders the whole instant as text.
                expectations.append(Expectation(argument: "-Composite:SubSecDateTimeOriginal",
                                                key: "Composite:SubSecDateTimeOriginal",
                                                expected: .text(stamp)))
            }
        }

        if let gps = edit.gps {
            let latitudeRef = gps.latitude < 0 ? "S" : "N"
            let longitudeRef = gps.longitude < 0 ? "W" : "E"
            if !toSidecar {
                // EXIF: unsigned magnitude plus a hemisphere reference.
                arguments.append("-EXIF:GPSLatitude=\(abs(gps.latitude))")
                arguments.append("-EXIF:GPSLatitudeRef=\(latitudeRef)")
                arguments.append("-EXIF:GPSLongitude=\(abs(gps.longitude))")
                arguments.append("-EXIF:GPSLongitudeRef=\(longitudeRef)")
                expectations.append(Expectation(
                    argument: "-GPS:GPSLatitude", key: "GPS:GPSLatitude",
                    expected: .number(abs(gps.latitude), tolerance: coordinateTolerance)))
                expectations.append(Expectation(
                    argument: "-GPS:GPSLatitudeRef", key: "GPS:GPSLatitudeRef",
                    expected: .text(latitudeRef)))
                expectations.append(Expectation(
                    argument: "-GPS:GPSLongitude", key: "GPS:GPSLongitude",
                    expected: .number(abs(gps.longitude), tolerance: coordinateTolerance)))
                expectations.append(Expectation(
                    argument: "-GPS:GPSLongitudeRef", key: "GPS:GPSLongitudeRef",
                    expected: .text(longitudeRef)))
            }
            // XMP: signed decimal degrees, no separate reference. Writing only
            // the EXIF half leaves the two families disagreeing on hemisphere.
            arguments.append("-XMP-exif:GPSLatitude=\(gps.latitude)")
            arguments.append("-XMP-exif:GPSLongitude=\(gps.longitude)")
            expectations.append(Expectation(
                argument: "-XMP-exif:GPSLatitude", key: "XMP-exif:GPSLatitude",
                expected: .number(gps.latitude, tolerance: coordinateTolerance)))
            expectations.append(Expectation(
                argument: "-XMP-exif:GPSLongitude", key: "XMP-exif:GPSLongitude",
                expected: .number(gps.longitude, tolerance: coordinateTolerance)))
        }

        return Plan(writeArguments: arguments, expectations: expectations)
    }

    /// One EXIF second is 1/3600 of a degree of latitude, about 31 m. exiftool
    /// writes far finer rationals than that, but a decimal degree still does
    /// not survive as an exact `Double`, so equality is asked for to about a
    /// centimetre rather than to the last bit.
    static let coordinateTolerance = 1e-6

    /// `yyyy:MM:dd HH:mm:ss[.sss]±HH:MM` — the form exiftool reads back from
    /// `MWG:DateTimeOriginal` and `Composite:SubSecDateTimeOriginal`.
    static func exifTimestamp(_ capture: CaptureTime, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = zone
        var stamp = formatter.string(from: capture.date)
        if let sub = capture.subSeconds, !sub.isEmpty { stamp += "." + sub }
        stamp += capture.offset ?? ""
        return stamp
    }

    // MARK: - Verification

    /// Reads the planned tags back and returns the keys that did not match.
    /// An empty array is the only thing that commits a write.
    static func verify(_ expectations: [Expectation], at url: URL,
                       runner: ExiftoolRunner) throws -> [String] {
        guard !expectations.isEmpty else { return [] }
        // `-n` for machine values (Rating as a number, GPS in decimal degrees
        // rather than "41 deg 52' 41.16\""), `-s` for short tag names, `-a` so
        // a duplicated tag is not silently collapsed, `-G1` so
        // `GPS:GPSLatitude` and `XMP-exif:GPSLatitude` stay distinguishable —
        // without it they share one JSON key and only one of them is checked.
        var arguments = ["-j", "-G1", "-n", "-s", "-a"]
        arguments.append(contentsOf: expectations.map(\.argument))

        let run = try runner.run(arguments: arguments, files: [url.path])
        let values = try parseJSON(run.stdout)

        var mismatched: [String] = []
        for expectation in expectations
        where !matches(expectation.expected, values[expectation.key]) {
            mismatched.append(expectation.key)
        }
        return mismatched
    }

    static func parseJSON(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            throw MetadataWriteError.exiftoolFailed(
                "could not parse exiftool JSON: \(text.prefix(400))")
        }
        return first
    }

    static func matches(_ expected: Expected, _ actual: Any?) -> Bool {
        switch expected {
        case .absent:
            return actual == nil
        case .text(let want):
            guard let actual else { return false }
            return stringValue(actual) == want
        case .integer(let want):
            guard let number = actual as? NSNumber else { return false }
            return number.intValue == want
        case .number(let want, let tolerance):
            guard let number = actual as? NSNumber else { return false }
            return abs(number.doubleValue - want) <= tolerance
        case .list(let want):
            guard let actual else { return false }
            // exiftool renders a one-element list tag as a bare string, so a
            // single keyword arrives as `"alpha"` and two arrive as an array.
            if let array = actual as? [Any] {
                return array.map(stringValue) == want
            }
            return [stringValue(actual)] == want
        }
    }

    private static func stringValue(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}
