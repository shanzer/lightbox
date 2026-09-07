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
    /// Something called `exiftool` is on `PATH` and is executable, but it did
    /// not answer `-ver`. Kept distinct from `notFound` because the two need
    /// different remedies — install it, versus work out what that file is. A
    /// dangling symlink, a half-finished Homebrew upgrade, and a shell wrapper
    /// that wants an interactive terminal all land here, and calling any of
    /// them "not found" sends the user looking in the wrong place.
    case unusable(path: String, reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var executablePath: String? {
        switch self {
        case .available(let path, _): path
        case .tooOld(let path, _, _): path
        case .unusable(let path, _): path
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
            Install it (`brew install exiftool`), then try again. \
            Browsing and search do not need it.
            """
        case .tooOld(let path, let version, let minimum):
            """
            Metadata editing needs exiftool \(minimum) or newer; \(path) reports \
            \(version). Upgrade it (`brew upgrade exiftool`), then try again. \
            Browsing and search do not need it.
            """
        case .unusable(let path, let reason):
            """
            Metadata editing needs exiftool. \(path) is on your PATH but did not \
            run: \(reason). Reinstall it (`brew reinstall exiftool`), then try \
            again. Browsing and search do not need it.
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
    /// - Parameter probeTimeout: how long `-ver` may take. Injectable so the
    ///   bound itself can be tested in well under the production budget.
    public static func check(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probeTimeout: TimeInterval = ExiftoolLocator.versionProbeTimeout
    ) -> ExiftoolAvailability {
        guard let path = locate(environment: environment) else { return .notFound }
        let version: String
        switch versionProbe(of: path, timeout: probeTimeout) {
        case .ok(let reported): version = reported
        case .failed(let reason): return .unusable(path: path, reason: reason)
        }
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

    /// The version string, or why it could not be obtained. The reason is
    /// carried rather than collapsed to nil so `.unusable` can say something
    /// more useful than "it did not work".
    private enum VersionProbe {
        case ok(String)
        case failed(String)
    }

    /// How long the version probe may take before the binary is called unusable.
    ///
    /// Generous for a program whose whole job here is to print one line, and
    /// short enough that a wedged probe is a message rather than a hang. Not a
    /// number to tune downward to make anything pass: it exists because the
    /// probe used to have *no* bound at all.
    public static let versionProbeTimeout: TimeInterval = 10

    private static func versionProbe(of path: String,
                                     timeout: TimeInterval) -> VersionProbe {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-ver"]
        let out = Pipe(), err = Pipe()
        // A prompting exiftool must fail rather than block on a tty.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failed("it could not be launched (\(error.localizedDescription))")
        }

        // **Neither `readDataToEndOfFile()` nor `waitUntilExit()`.** Both are
        // unbounded, and this function is called from ordinary test and app
        // code on a cooperative-pool thread; a thread blocked there never comes
        // back, and enough of them starve the pool so that unrelated work stops
        // dead. `PipeDrain` reads both descriptors against a deadline —
        // draining stderr too, so a chatty probe cannot fill its pipe and wedge
        // — and `endProcess` bounds the reaping.
        let deadline = Date().addingTimeInterval(timeout)
        let drained: PipeDrain.Result
        do {
            drained = try PipeDrain.readToEnd(
                first: out.fileHandleForReading.fileDescriptor,
                second: err.fileHandleForReading.fileDescriptor,
                deadline: deadline)
        } catch {
            ExiftoolRunner.endProcess(process, force: true)
            return .failed("`-ver` did not answer within \(Int(timeout))s")
        }
        guard ExiftoolRunner.endProcess(process) else {
            return .failed("`-ver` did not exit")
        }
        guard process.terminationStatus == 0 else {
            return .failed("`-ver` exited \(process.terminationStatus)")
        }
        let text = String(decoding: drained.first, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failed("`-ver` printed nothing") : .ok(text)
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
