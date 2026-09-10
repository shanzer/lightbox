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
            Metadata editing needs exiftool, which was not found. Lightbox \
            looked on your PATH, asked your login shell where it is, and looked \
            in \(ExiftoolLocator.fallbackPrefixes.joined(separator: ", ")). \
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
            Metadata editing needs exiftool. \(path) was found but did not \
            run: \(reason). Reinstall it (`brew reinstall exiftool`), then try \
            again. Browsing and search do not need it.
            """
        }
    }
}

/// Finds exiftool and reads its version.
///
/// ## The four rungs (#41)
///
/// 1. `LIGHTBOX_EXIFTOOL` — an explicit override, and it wins over everything.
/// 2. `PATH` — the answer for a terminal-launched build and for CI.
/// 3. **The user's login shell**, asked only when `PATH` misses:
///    `<login shell> -l -c 'command -v exiftool'`.
/// 4. **A named fallback list**, tried only when the shell misses:
///    `fallbackPrefixes`.
///
/// Rungs 3 and 4 exist because **a GUI-launched process does not get the user's
/// shell `PATH`**. Finder and the Dock hand a bundle launchd's built-in
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — measured, HANDOFF §7.9 — so a
/// `PATH`-only lookup answers `.notFound` on a machine that has exiftool, and
/// every launch an actual user performs is a GUI launch. Rung 3 asks the user's
/// own configuration rather than guessing; rung 4 is a list of places to look
/// *after* that has been asked, not "the" location. The standing rule that no
/// Homebrew prefix is *the* answer still holds: neither prefix is consulted
/// until the user's `PATH` and the user's login shell have both been asked, and
/// `/opt/local/bin` is there so the list is not a Homebrew special case.
///
/// **This dies under App Sandbox.** `ENABLE_HARDENED_RUNTIME` is `NO` and there
/// is no entitlements file today, so forking a login shell and executing a
/// Homebrew binary is allowed. Sandboxing Lightbox for distribution would take
/// rungs 3 and 4 with it, and a stored preference (#51) becomes the only route.
///
/// The `LIGHTBOX_EXIFTOOL` environment variable overrides the search, which is
/// what a test needs to point at a stub and what a user needs for a
/// non-standard install; it is one `if let`, not a settings system.
public enum ExiftoolLocator {
    /// The oldest exiftool this code has been checked against. MWG composite
    /// writing has been stable for far longer, but a floor makes the failure a
    /// message instead of a mystery.
    public static let minimumVersion = "13.0"

    public static let overrideEnvironmentKey = "LIGHTBOX_EXIFTOOL"

    /// Rung 4: where to look once the user's own configuration has been asked
    /// and has not answered.
    ///
    /// Homebrew is `/opt/homebrew/bin` on Apple silicon and `/usr/local/bin` on
    /// Intel — this project has already moved between those two machines once
    /// (HANDOFF §3), which is why neither may be hardcoded as *the* prefix —
    /// and `/opt/local/bin` is MacPorts. Order is Apple silicon first because
    /// that is where an Intel-era `/usr/local/bin` leftover is most likely to be
    /// the stale one.
    public static let fallbackPrefixes = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
    ]

    /// Rung 3: a function that asks something where exiftool is, given the
    /// environment the lookup is running in.
    ///
    /// A parameter rather than a hardwired call so `locate(environment:)` stays
    /// pure — see the `shellProbe:` parameter's note there for why its default
    /// is *no probe at all*.
    public typealias ShellProbe = @Sendable (_ environment: [String: String]) -> String?

    // MARK: - Production entry points

    /// The absolute path of the exiftool that would be run, or nil.
    ///
    /// One line, forwarding to `locate(systemEnvironment:)` — which is the
    /// production resolution order with its environment injectable, so a test
    /// can prove this path really carries the shell probe and the prefixes
    /// rather than silently degrading to rungs 1 and 2.
    public static func locate() -> String? {
        locate(systemEnvironment: ProcessInfo.processInfo.environment)
    }

    /// Locates exiftool and asks it for its version.
    public static func check(
        probeTimeout: TimeInterval = ExiftoolLocator.versionProbeTimeout
    ) -> ExiftoolAvailability {
        check(systemEnvironment: ProcessInfo.processInfo.environment,
              probeTimeout: probeTimeout)
    }

    /// The production order — all four rungs, the real login shell — with only
    /// the environment injected.
    ///
    /// Internal, and the thing the "does production carry the fix?" tests call.
    /// Without it the only way to reach the wired-up order is `locate()`, whose
    /// environment cannot be controlled from a test, and the injected-probe
    /// default below could be left in place everywhere with every test still
    /// green (HANDOFF §6: a test that passes without exercising the code is
    /// worse than none).
    static func locate(systemEnvironment environment: [String: String],
                       shellProbeTimeout: TimeInterval = loginShellProbeTimeout) -> String? {
        locate(environment: environment,
               shellProbe: loginShellProbe(timeout: shellProbeTimeout),
               prefixes: fallbackPrefixes)
    }

    /// `check`'s half of the same seam.
    static func check(systemEnvironment environment: [String: String],
                      probeTimeout: TimeInterval = ExiftoolLocator.versionProbeTimeout,
                      shellProbeTimeout: TimeInterval = loginShellProbeTimeout)
    -> ExiftoolAvailability {
        check(environment: environment,
              probeTimeout: probeTimeout,
              shellProbe: loginShellProbe(timeout: shellProbeTimeout),
              prefixes: fallbackPrefixes)
    }

    // MARK: - The resolution order

    /// The rungs, over an environment and whatever else the caller supplies.
    ///
    /// - Parameters:
    ///   - environment: the environment to resolve against. No default: the
    ///     production environment arrives through `locate()`, and a caller that
    ///     names an environment is asking for exactly the rungs it also names.
    ///   - shellProbe: rung 3, **absent by default**. `MetadataWriterTests`
    ///     asserts that `locate(environment: ["PATH": "/nonexistent-bin"])` is
    ///     nil; if this defaulted to the real probe, that test would fork the
    ///     developer's login shell, find their real exiftool, and go red on
    ///     every machine that has one.
    ///   - prefixes: rung 4, **empty by default**, for the same reason — the
    ///     hardcoded-prefix test would otherwise find `/opt/homebrew/bin`.
    public static func locate(environment: [String: String],
                              shellProbe: ShellProbe? = nil,
                              prefixes: [String] = []) -> String? {
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent("exiftool").path
                if isExecutable(candidate) { return candidate }
            }
        }
        if let shellProbe, let answer = shellProbe(environment),
           let believable = accept(probeOutput: answer) {
            return believable
        }
        for prefix in prefixes {
            let candidate = URL(fileURLWithPath: prefix)
                .appendingPathComponent("exiftool").path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Locates exiftool and asks it for its version.
    /// - Parameter probeTimeout: how long `-ver` may take. Injectable so the
    ///   bound itself can be tested in well under the production budget.
    public static func check(
        environment: [String: String],
        probeTimeout: TimeInterval = ExiftoolLocator.versionProbeTimeout,
        shellProbe: ShellProbe? = nil,
        prefixes: [String] = []
    ) -> ExiftoolAvailability {
        guard let path = locate(environment: environment,
                                shellProbe: shellProbe,
                                prefixes: prefixes) else { return .notFound }
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

    // MARK: - Rung 3: the login shell

    /// How long the login shell may take to answer `command -v exiftool`.
    ///
    /// Measured on the M4 mini at 0.01–0.02 s for `zsh -l -c` under `env -i`;
    /// five seconds is 250× that. It is generous because the thing being run is
    /// the *user's* startup files, which may do arbitrary work, and short
    /// because `MetadataWriter.availability` is synchronous and this is now the
    /// first of two forks it may pay for.
    public static let loginShellProbeTimeout: TimeInterval = 5

    /// The real rung 3.
    ///
    /// **`-l -c`, not `-l -i -c`.** A *login* non-interactive zsh sources
    /// `/etc/zprofile`, `~/.zprofile` and `~/.zlogin` — where `brew shellenv`
    /// lands — and skips `~/.zshrc`, where the slow and tty-dependent things
    /// live. Measured here, `command -v exiftool` under `env -i`: `-l -c` takes
    /// 0.01–0.02 s, `-l -i -c` 0.49–0.67 s.
    ///
    /// **The user's real login shell, not `/bin/sh`.** `/bin/sh` on macOS is
    /// bash in POSIX mode; with `-l` it sources `/etc/profile` and `~/.profile`
    /// and *never* `~/.zprofile`, which is the file Homebrew's installer writes
    /// its `PATH` line into. On this machine `sh -lc` answers anyway — only
    /// because `/etc/paths.d/homebrew` exists and `path_helper` picks it up — so
    /// getting this wrong ships a mechanism that is dead everywhere except the
    /// machine it was written on.
    static func loginShellProbe(timeout: TimeInterval = loginShellProbeTimeout) -> ShellProbe {
        { environment in
            guard let shell = loginShellPath(environment: environment) else { return nil }
            return ask(shell: shell, environment: environment, timeout: timeout)
        }
    }

    /// The user's login shell: `SHELL` if it names one, else the passwd entry.
    ///
    /// `SHELL` is **present in a Finder-launched process** — measured alongside
    /// the truncated `PATH` — so the common case never touches passwd. The
    /// passwd fallback covers a launch context that strips it.
    ///
    /// Nothing here is believed on sight: a `SHELL` naming a relative path or a
    /// file that is not executable is discarded rather than handed to `Process`.
    static func loginShellPath(environment: [String: String]) -> String? {
        if let shell = environment["SHELL"], shell.hasPrefix("/"), isExecutable(shell) {
            return shell
        }
        guard let shell = passwdShell(), shell.hasPrefix("/"), isExecutable(shell) else {
            return nil
        }
        return shell
    }

    /// `getpwuid_r` rather than `getpwuid`: the latter returns a pointer into
    /// static storage that the next caller on any thread overwrites, and this
    /// runs from whichever thread reached `MetadataWriter.availability` first.
    private static func passwdShell() -> String? {
        var storage = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(getuid(), &storage, &buffer, buffer.count, &result) == 0,
              result != nil, let shell = storage.pw_shell else { return nil }
        return String(cString: shell)
    }

    /// Runs the shell and returns whatever it printed on stdout, unexamined.
    ///
    /// Bounded exactly the way `versionProbe` is, and for the same reason: this
    /// is called from `MetadataWriter.availability`, which is synchronous and
    /// therefore runs on whatever thread asked — a cooperative-pool thread,
    /// usually. `stdin` is the null device so a shell that wants a tty fails
    /// instead of blocking, both pipes drain against a deadline rather than
    /// through an unbounded `readDataToEndOfFile` (#28/#30), and the reaping
    /// goes through `ExiftoolRunner.endProcess`.
    ///
    /// The child gets exactly the environment this lookup was given, not the
    /// process's own, so `locate(environment:shellProbe:)` remains a function of
    /// its arguments. In production the two are the same dictionary.
    ///
    /// The deadline is on **EOF, not on exit**, which is what makes it robust:
    /// a startup file that backgrounds something holding the inherited pipe open
    /// costs the full timeout and then falls through to rung 4, rather than
    /// hanging. That is the worst case worth knowing about, and it is five
    /// seconds paid once per process.
    private static func ask(shell: String,
                            environment: [String: String],
                            timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l -c` rather than `-lc`: identical for zsh and bash, and the
        // separated form is also what fish accepts. A shell that understands
        // neither simply fails to launch or exits non-zero, and rung 4 follows.
        process.arguments = ["-l", "-c", "command -v exiftool"]
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        let drained: PipeDrain.Result
        do {
            drained = try PipeDrain.readToEnd(
                first: out.fileHandleForReading.fileDescriptor,
                second: err.fileHandleForReading.fileDescriptor,
                deadline: deadline)
        } catch {
            ExiftoolRunner.endProcess(process, force: true)
            return nil
        }
        guard ExiftoolRunner.endProcess(process),
              process.terminationStatus == 0 else { return nil }
        return String(decoding: drained.first, as: UTF8.self)
    }

    /// What a shell probe said, if it can be believed.
    ///
    /// The probe executed the user's own startup files, so it ran at their
    /// privilege and is not an escalation — but the *answer* is a string
    /// produced by an arbitrary script, and a `~/.zprofile` that prints a banner
    /// must not turn its first word into the path Lightbox execs. Hence: the
    /// **first line only**, it must be **absolute**, and it must survive the
    /// same `isExecutable` check every other rung goes through.
    static func accept(probeOutput output: String) -> String? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: false).first
        else { return nil }
        let candidate = line.trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("/"), isExecutable(candidate) else { return nil }
        return candidate
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
