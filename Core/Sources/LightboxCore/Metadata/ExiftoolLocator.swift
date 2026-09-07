import Foundation

/// Whether exiftool can be used, and if not, what to tell the user.
///
/// Spec §11: exiftool absent means editing is disabled with an explanation;
/// browsing and search are unaffected. Nothing here throws, and nothing here
/// runs at launch — the lookup happens at first use.
public enum ExiftoolAvailability: Sendable, Equatable {
    case available(path: String, version: String)
    case notFound
    case tooOld(path: String, version: String, minimum: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var executablePath: String? {
        switch self {
        case .available(let path, _): path
        case .tooOld(let path, _, _): path
        case .notFound: nil
        }
    }

    /// The sentence the inspector shows where the editing controls would be.
    public var explanation: String? {
        switch self {
        case .available:
            nil
        case .notFound:
            """
            Metadata editing needs exiftool, which was not found on your PATH. \
            Install it (`brew install exiftool`) and reopen the window. \
            Browsing and search do not need it.
            """
        case .tooOld(let path, let version, let minimum):
            """
            Metadata editing needs exiftool \(minimum) or newer; \(path) reports \
            \(version). Upgrade it (`brew upgrade exiftool`) and reopen the window. \
            Browsing and search do not need it.
            """
        }
    }
}

/// Finds exiftool and reads its version.
///
/// **Resolved through `PATH`, never a hardcoded prefix.** Homebrew puts it at
/// `/opt/homebrew/bin` on Apple silicon and `/usr/local/bin` on Intel, and this
/// project has already moved between those two machines once (HANDOFF §3). The
/// `LIGHTBOX_EXIFTOOL` environment variable overrides the search, which is what
/// a test needs to point at a stub and what a user needs for a non-standard
/// install; it is one `if let`, not a settings system.
public enum ExiftoolLocator {
    /// The oldest exiftool this code has been checked against. MWG composite
    /// writing has been stable for far longer, but a floor makes the failure a
    /// message instead of a mystery.
    public static let minimumVersion = "13.0"

    public static let overrideEnvironmentKey = "LIGHTBOX_EXIFTOOL"

    /// The absolute path of the exiftool that would be run, or nil.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("exiftool").path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Locates exiftool and asks it for its version.
    public static func check(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExiftoolAvailability {
        guard let path = locate(environment: environment) else { return .notFound }
        guard let version = version(of: path) else { return .notFound }
        guard isAtLeastMinimum(version) else {
            return .tooOld(path: path, version: version, minimum: minimumVersion)
        }
        return .available(path: path, version: version)
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-ver"]
        let out = Pipe()
        // A prompting exiftool must fail rather than block on a tty.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// exiftool versions are `major.minor`, sometimes with a trailing letter on
    /// a pre-release. Compared numerically component by component so `13.9` is
    /// correctly older than `13.55` — a plain string compare gets that backwards.
    static func isAtLeastMinimum(_ version: String) -> Bool {
        compare(version, minimumVersion) >= 0
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}
