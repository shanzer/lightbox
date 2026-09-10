import Testing
import Foundation
import ImageIO
@testable import LightboxCore

// MARK: - Skip guard

/// Every round-trip test below runs the *real* exiftool. A stub would prove
/// nothing about the tag mapping, which is the whole substance of this feature.
///
/// The guard consults `MetadataWriter.availability` — the same lookup the
/// writer performs, as CONTRIBUTING requires. A guard that checked, say, the
/// existence of `/opt/homebrew/bin/exiftool` while the writer searched `PATH`
/// would produce a green run on CI that proves nothing at all.
private let needsExiftool = ConditionTrait.enabled(
    if: MetadataWriter.availability.isAvailable,
    "exiftool was not found — MetadataWriter round-trip tests skipped")

// MARK: - Locating exiftool (no binary needed)

struct ExiftoolLocatorTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Creates a directory holding an executable file called `exiftool`.
    private func fakeBinDirectory(named name: String = "bin") throws -> URL {
        let directory = try tree.directory(name)
        let binary = directory.appendingPathComponent("exiftool")
        try "#!/bin/sh\necho 13.55\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)
        return directory
    }

    @Test func findsExiftoolOnPATH() throws {
        let directory = try fakeBinDirectory()
        let found = ExiftoolLocator.locate(environment: ["PATH": "/nowhere:\(directory.path)"])
        #expect(found == directory.appendingPathComponent("exiftool").path)
    }

    /// The bug this guards against is a hardcoded `/opt/homebrew/bin` or
    /// `/usr/local/bin`, which HANDOFF §3 calls out by name: the project moved
    /// between an Intel iMac and an M4 mini, and those are the two prefixes.
    /// A locator that quietly falls back to either one would pass every other
    /// test on this machine and fail on the other.
    @Test func doesNotFallBackToAHardcodedHomebrewPrefix() {
        #expect(ExiftoolLocator.locate(environment: ["PATH": "/nonexistent-bin"]) == nil)
        #expect(ExiftoolLocator.locate(environment: [:]) == nil)
    }

    @Test func skipsDirectoriesAndNonExecutables() throws {
        let directory = try tree.directory("notbin")
        try tree.directory("notbin/exiftool")            // a *directory* named exiftool
        #expect(ExiftoolLocator.locate(environment: ["PATH": directory.path]) == nil)

        let plain = try tree.directory("plain")
        try "not executable".write(to: plain.appendingPathComponent("exiftool"),
                                   atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: plain.appendingPathComponent("exiftool").path)
        #expect(ExiftoolLocator.locate(environment: ["PATH": plain.path]) == nil)
    }

    @Test func environmentOverrideWinsOverPATH() throws {
        let onPath = try fakeBinDirectory(named: "onpath")
        let elsewhere = try fakeBinDirectory(named: "elsewhere")
        let override = elsewhere.appendingPathComponent("exiftool").path
        let found = ExiftoolLocator.locate(environment: [
            "PATH": onPath.path,
            ExiftoolLocator.overrideEnvironmentKey: override,
        ])
        #expect(found == override)
    }

    /// A file called `exiftool` that is executable but does not answer `-ver`
    /// is a different problem from no exiftool at all, and needs a different
    /// sentence: "install it" is useless advice when it *is* installed. A
    /// dangling symlink and a half-finished Homebrew upgrade both look like
    /// this.
    @Test func anExecutableThatDoesNotAnswerVerIsUnusableNotMissing() throws {
        let directory = try tree.directory("broken")
        let binary = directory.appendingPathComponent("exiftool")
        try "#!/bin/sh\nexit 3\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)

        let availability = ExiftoolLocator.check(environment: ["PATH": directory.path])
        guard case .unusable(let path, let reason) = availability else {
            Issue.record("expected .unusable, got \(availability)")
            return
        }
        #expect(path == binary.path)
        #expect(reason.contains("3"))
        #expect(!availability.isAvailable)
        #expect(availability.explanation?.contains(binary.path) == true)
    }

    /// One that runs but prints nothing is the same class of problem.
    @Test func anExecutableThatPrintsNoVersionIsUnusable() throws {
        let directory = try tree.directory("silent")
        let binary = directory.appendingPathComponent("exiftool")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)

        guard case .unusable = ExiftoolLocator.check(environment: ["PATH": directory.path]) else {
            Issue.record("expected .unusable for a binary that prints no version")
            return
        }
    }

    /// **The CI hang.** A `-ver` probe used to be read with
    /// `readDataToEndOfFile()` and waited on with `waitUntilExit()`, neither of
    /// which has a bound. A binary that prints its version and then keeps the
    /// pipe open — or simply never exits — parked the calling thread forever.
    /// That thread is a cooperative-pool thread, and on a three-core runner
    /// three such blocks starved the pool: 141 tests never ran, every suite
    /// showed "started" and none showed "passed", and the job had to be killed
    /// after fourteen minutes.
    ///
    /// A probe that does not answer is *unusable*, which is a true statement
    /// about the binary and a message the user can act on.
    @Test(arguments: ["#!/bin/sh\nsleep 60\n",                    // never exits
                      "#!/bin/sh\necho 13.55\nsleep 60\n",        // answers, holds the pipe
                      "#!/bin/sh\nexec sleep 60\n"])              // no output at all
    func aVersionProbeThatNeverAnswersIsBoundedNotHung(_ script: String) throws {
        let directory = try tree.directory("hangs-\(abs(script.hashValue % 100_000))")
        let binary = directory.appendingPathComponent("exiftool")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)

        let started = Date()
        let availability = ExiftoolLocator.check(environment: ["PATH": directory.path],
                                                 probeTimeout: 0.75)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 20, "the version probe must be bounded; it took \(elapsed)s")
        #expect(!availability.isAvailable)
        guard case .unusable = availability else {
            Issue.record("expected .unusable for a probe that never answers, got \(availability)")
            return
        }
    }

    /// exiftool's versions are `13.9`, `13.10`, `13.55`. A lexical compare puts
    /// `13.9` *after* `13.55`, so a minimum-version check written with `>=` on
    /// strings would reject a newer exiftool than the one it demands.
    @Test func versionsCompareNumericallyNotLexically() {
        #expect(ExiftoolLocator.compare("13.9", "13.55") < 0)
        #expect(ExiftoolLocator.compare("13.55", "13.9") > 0)
        #expect(ExiftoolLocator.compare("13.55", "13.55") == 0)
        #expect(ExiftoolLocator.compare("14.0", "13.99") > 0)
        #expect(ExiftoolLocator.isAtLeastMinimum("13.55"))
        #expect(ExiftoolLocator.isAtLeastMinimum("13.0"))
        #expect(!ExiftoolLocator.isAtLeastMinimum("12.99"))
    }

    /// Spec §11: exiftool absent disables editing *with an explanation*, and
    /// leaves everything else alone.
    @Test func absentExiftoolExplainsItselfAndFailsEveryItem() async throws {
        #expect(ExiftoolAvailability.notFound.explanation?.contains("exiftool") == true)
        #expect(ExiftoolAvailability.notFound.isAvailable == false)
        #expect(ExiftoolAvailability.tooOld(path: "/x", version: "12.0", minimum: "13.0")
            .isAvailable == false)

        let writer = MetadataWriter(availability: .notFound)
        let url = try tree.file("a.jpg")
        let outcomes = await writer.write(MetadataEdit(description: "x"), to: [url])
        #expect(outcomes.count == 1)
        guard case .exiftoolUnavailable(let reason) = outcomes[0].error else {
            Issue.record("expected .exiftoolUnavailable, got \(String(describing: outcomes[0].error))")
            return
        }
        #expect(reason.contains("exiftool"))
    }
}

// MARK: - The four-rung lookup order (#41)

/// A GUI-launched process gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so a
/// `PATH`-only lookup answers `.notFound` on a machine that has exiftool and
/// metadata editing is dead for every user who double-clicks the app. These
/// cover the two rungs added for that — the login shell, then a named prefix
/// list — and, as much as the seam allows, the fact that the *production* entry
/// point really carries them.
struct ExiftoolLookupOrderTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// A directory holding an executable `exiftool` that answers `-ver`.
    private func fakeBinDirectory(named name: String) throws -> URL {
        let directory = try tree.directory(name)
        try script(at: directory.appendingPathComponent("exiftool"),
                   "#!/bin/sh\necho 13.55\n")
        return directory
    }

    private func script(at url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    /// A `PATH` with nothing on it — a stand-in for launchd's
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, which cannot be used literally here
    /// because a machine is free to have exiftool in `/usr/bin`.
    private func emptyPath() throws -> String { try tree.directory("empty-path").path }

    // MARK: Rung 3 — the login shell

    @Test func theLoginShellIsAskedWhenPATHMisses() throws {
        let installed = try fakeBinDirectory(named: "brewish")
            .appendingPathComponent("exiftool").path
        let environment = ["PATH": try emptyPath()]

        let found = ExiftoolLocator.locate(environment: environment,
                                           shellProbe: { _ in installed })
        #expect(found == installed)

        let availability = ExiftoolLocator.check(environment: environment,
                                                 shellProbe: { _ in installed })
        #expect(availability == .available(path: installed, version: "13.55"))
    }

    /// Rung 4 is a list of places to look *after* the user's own configuration
    /// has been asked, so it must not be reached while the shell is answering.
    @Test func theShellsAnswerBeatsTheFallbackPrefixes() throws {
        let fromShell = try fakeBinDirectory(named: "from-shell")
            .appendingPathComponent("exiftool").path
        let prefix = try fakeBinDirectory(named: "prefix")

        let found = ExiftoolLocator.locate(environment: ["PATH": try emptyPath()],
                                           shellProbe: { _ in fromShell },
                                           prefixes: [prefix.path])
        #expect(found == fromShell)
    }

    /// The whole point of the ordering: an override still wins outright, a
    /// `PATH` hit is still the answer for a terminal-launched build, and in
    /// that case **the shell is not forked at all** — this is on
    /// `MetadataWriter.availability`'s synchronous path, and a fork nobody
    /// needs is a parked cooperative thread nobody needs.
    @Test func precedenceRunsOverrideThenPATHThenShellThenPrefixes() throws {
        let onPath = try fakeBinDirectory(named: "onpath")
        let override = try fakeBinDirectory(named: "override")
            .appendingPathComponent("exiftool").path
        let fromShell = try fakeBinDirectory(named: "shell")
            .appendingPathComponent("exiftool").path
        let prefix = try fakeBinDirectory(named: "prefixdir")

        let forks = Counter()
        let countingProbe: ExiftoolLocator.ShellProbe = { _ in
            forks.increment()
            return fromShell
        }

        #expect(ExiftoolLocator.locate(
            environment: ["PATH": onPath.path,
                          ExiftoolLocator.overrideEnvironmentKey: override],
            shellProbe: countingProbe, prefixes: [prefix.path]) == override)
        #expect(forks.value == 0, "an override must not fork a shell")

        #expect(ExiftoolLocator.locate(
            environment: ["PATH": onPath.path],
            shellProbe: countingProbe,
            prefixes: [prefix.path]) == onPath.appendingPathComponent("exiftool").path)
        #expect(forks.value == 0, "a PATH hit must not fork a shell")

        #expect(ExiftoolLocator.locate(
            environment: ["PATH": try emptyPath()],
            shellProbe: countingProbe, prefixes: [prefix.path]) == fromShell)
        #expect(forks.value == 1)

        #expect(ExiftoolLocator.locate(
            environment: ["PATH": try emptyPath()],
            shellProbe: { _ in nil },
            prefixes: [prefix.path]) == prefix.appendingPathComponent("exiftool").path)
    }

    /// Nothing anywhere is `.notFound`, and the sentence has to name what was
    /// searched: "not found on your PATH" sends a user who *has* exiftool
    /// looking in the wrong place, which is exactly how #41 presented.
    @Test func nothingAnywhereIsNotFoundAndTheSentenceNamesEveryRung() throws {
        let availability = ExiftoolLocator.check(environment: ["PATH": try emptyPath()],
                                                 shellProbe: { _ in nil },
                                                 prefixes: [try tree.directory("nope").path])
        #expect(availability == .notFound)

        let sentence = try #require(availability.explanation)
        #expect(sentence.contains("PATH"))
        #expect(sentence.localizedCaseInsensitiveContains("login shell"))
        for prefix in ExiftoolLocator.fallbackPrefixes {
            #expect(sentence.contains(prefix), "the sentence does not name \(prefix)")
        }
    }

    // MARK: Believing the shell

    /// The probe runs the user's own startup files, so it is their privilege
    /// and not an escalation — but its *output* is a string from an arbitrary
    /// script, and Lightbox is about to `exec` it. A `~/.zprofile` that prints
    /// a banner must not turn its first word into an exiftool.
    @Test func hostileProbeOutputIsRejected() throws {
        let real = try fakeBinDirectory(named: "real")
            .appendingPathComponent("exiftool").path

        // The first line only — trailing noise is ignored...
        #expect(ExiftoolLocator.accept(probeOutput: "\(real)\n/bin/rm\n") == real)
        #expect(ExiftoolLocator.accept(probeOutput: "\(real)\n") == real)
        // ...and a banner ahead of the answer is not searched past.
        #expect(ExiftoolLocator.accept(probeOutput: "Welcome!\n\(real)\n") == nil)

        #expect(ExiftoolLocator.accept(probeOutput: "exiftool") == nil,      // relative
                "a relative path must not be believed")
        #expect(ExiftoolLocator.accept(probeOutput: "bin/exiftool") == nil)  // relative
        #expect(ExiftoolLocator.accept(probeOutput: "/nonexistent/exiftool") == nil)
        #expect(ExiftoolLocator.accept(probeOutput: "") == nil)
        #expect(ExiftoolLocator.accept(probeOutput: "\n\(real)") == nil)

        let plain = try tree.directory("plain-answer").appendingPathComponent("exiftool")
        try "not executable".write(to: plain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: plain.path)
        #expect(ExiftoolLocator.accept(probeOutput: plain.path) == nil)

        // And the rejection is the locator's, not merely the helper's.
        #expect(ExiftoolLocator.locate(environment: ["PATH": try emptyPath()],
                                       shellProbe: { _ in "Welcome!\n\(real)\n" }) == nil)
    }

    // MARK: The real probe

    /// The same hazard as `aVersionProbeThatNeverAnswersIsBoundedNotHung`, one
    /// fork earlier: this runs on a cooperative-pool thread, so a shell that
    /// never answers must be abandoned rather than waited on. A `~/.zprofile`
    /// that reads from a tty is the realistic version of it.
    @Test func aLoginShellThatNeverAnswersIsAbandonedAtTheTimeout() throws {
        let shell = try tree.directory("hanging-shell").appendingPathComponent("sh")
        try script(at: shell, "#!/bin/sh\nsleep 60\n")

        let started = Date()
        let answer = ExiftoolLocator.loginShellProbe(timeout: 0.75)(["SHELL": shell.path])
        let elapsed = Date().timeIntervalSince(started)

        #expect(answer == nil)
        #expect(elapsed < 20, "the login-shell probe must be bounded; it took \(elapsed)s")
    }

    /// A shell that exits non-zero — which is what `command -v` does when it
    /// finds nothing — is a miss, not a crash, and rung 4 follows it.
    @Test func aShellThatFindsNothingIsAMiss() throws {
        let shell = try tree.directory("empty-shell").appendingPathComponent("sh")
        try script(at: shell, "#!/bin/sh\nexit 1\n")
        #expect(ExiftoolLocator.loginShellProbe()(["SHELL": shell.path]) == nil)
    }

    /// `SHELL` is present in a Finder-launched process, so it is the first
    /// source — but it is not believed on sight, and the passwd entry is the
    /// fallback for a launch context that strips it.
    @Test func theLoginShellIsSHELLThenPasswdAndNeitherIsBelievedOnSight() throws {
        let shell = try tree.directory("a-shell").appendingPathComponent("sh")
        try script(at: shell, "#!/bin/sh\nexit 0\n")
        #expect(ExiftoolLocator.loginShellPath(environment: ["SHELL": shell.path]) == shell.path)

        // Relative, missing, and not executable all fall through to passwd,
        // which on any account this test can run under names a real shell.
        let passwdShell = try #require(ExiftoolLocator.loginShellPath(environment: [:]))
        #expect(passwdShell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: passwdShell))
        #expect(ExiftoolLocator.loginShellPath(environment: ["SHELL": "zsh"]) == passwdShell)
        #expect(ExiftoolLocator.loginShellPath(
            environment: ["SHELL": "/nonexistent/shell"]) == passwdShell)
    }

    // MARK: The production wiring

    /// **The seam that can silently disable the whole fix.** `shellProbe:` and
    /// `prefixes:` default to absent on the `environment:`-taking overload — they
    /// have to, or `doesNotFallBackToAHardcodedHomebrewPrefix` would fork the
    /// developer's shell and find their real exiftool. So every test above would
    /// still pass with the production order wired to those defaults, and #41
    /// would ship unfixed.
    ///
    /// `locate(systemEnvironment:)` is the production order with only its
    /// environment injected; `locate()` is a one-line forward to it.
    @Test func theProductionOrderCarriesTheRealShellProbe() throws {
        let installed = try fakeBinDirectory(named: "installed")
            .appendingPathComponent("exiftool").path
        let shell = try tree.directory("answering-shell").appendingPathComponent("sh")
        try script(at: shell, "#!/bin/sh\necho '\(installed)'\n")

        let environment = ["PATH": try emptyPath(), "SHELL": shell.path]
        #expect(ExiftoolLocator.locate(systemEnvironment: environment) == installed)
        #expect(ExiftoolLocator.check(systemEnvironment: environment)
                == .available(path: installed, version: "13.55"))
    }

    /// And the same for rung 4. Vacuous on CI, which has exiftool in none of
    /// the three prefixes and would answer nil either way; on any developer
    /// machine with a Homebrew or MacPorts exiftool it is the real check.
    @Test func theProductionOrderCarriesTheFallbackPrefixes() throws {
        let silent = try tree.directory("silent-shell").appendingPathComponent("sh")
        try script(at: silent, "#!/bin/sh\nexit 1\n")

        let expected = ExiftoolLocator.fallbackPrefixes
            .map { URL(fileURLWithPath: $0).appendingPathComponent("exiftool").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        #expect(ExiftoolLocator.locate(
            systemEnvironment: ["PATH": try emptyPath(), "SHELL": silent.path]) == expected)
    }
}

/// A fork counter for the precedence test. `nonisolated(unsafe)` would do —
/// nothing here is concurrent — but a lock costs nothing and does not have to
/// be re-reasoned about if a later test hands the probe to two threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - What the API refuses (no binary needed)

struct MetadataWriteValidationTests {
    /// Spec §9, constraint 1. Refused *at the API*, not merely discouraged in
    /// the inspector: a `DateTimeOriginal` with no `OffsetTimeOriginal` names a
    /// different instant on every machine that reads it.
    @Test func refusesACaptureTimeWithNoTimeZone() {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: nil))
        #expect(MetadataWriter.validate(edit) == .captureTimeRequiresTimeZone)

        let blank = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: "  "))
        #expect(MetadataWriter.validate(blank) == .captureTimeRequiresTimeZone)
    }

    /// An offset the *reader* cannot parse would round-trip to a different
    /// instant, so the writer refuses exactly what `MetadataReader` refuses.
    @Test(arguments: ["-5:00", "EST", "+05", "-05:00:00", "05:00"])
    func refusesAnOffsetTheReaderCannotParse(_ offset: String) {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: offset))
        #expect(MetadataWriter.validate(edit) == .invalidTimeZoneOffset(offset))
    }

    @Test func acceptsAWellFormedOffset() {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: "-05:00"))
        #expect(MetadataWriter.validate(edit) == nil)
    }

    @Test func refusesNonNumericSubSeconds() {
        let capture = CaptureTime(date: Date(), offset: "+00:00", subSeconds: "12x")
        #expect(MetadataWriter.validate(MetadataEdit(captureTime: capture))
            == .invalidSubSeconds("12x"))
    }

    @Test(arguments: [-1, 6, 99]) func refusesARatingOutsideZeroToFive(_ rating: Int) {
        #expect(MetadataWriter.validate(MetadataEdit(rating: rating)) == .invalidRating(rating))
    }

    @Test func refusesAnImpossibleCoordinate() {
        let edit = MetadataEdit(gps: GPSCoordinate(latitude: 91, longitude: 0))
        #expect(MetadataWriter.validate(edit) == .invalidCoordinate(latitude: 91, longitude: 0))
    }

    @Test func refusesAnEmptyEdit() {
        #expect(MetadataWriter.validate(MetadataEdit()) == .nothingToWrite)
    }
}

// MARK: - Hostile-argument routing (no binary needed)

/// Spec §9, constraint 4. The `-stay_open` argument protocol is newline
/// delimited *and* strips surrounding whitespace from each line, so these
/// inputs are argument injection rather than mere breakage.
struct ExiftoolRoutingTests {
    @Test func ordinaryArgumentsTakeTheStayOpenPath() {
        #expect(!ExiftoolRunner.requiresOneShot(
            arguments: ["-MWG:Description=a normal caption"],
            files: ["/tmp/photos/IMG_0001.jpg"]))
    }

    @Test(arguments: ["a\nb", "a\rb", "a\r\nb", "a\u{0}b"])
    func aValueCarryingALineBreakIsRoutedToTheOneShot(_ value: String) {
        #expect(ExiftoolRunner.requiresOneShot(
            arguments: ["-MWG:Description=\(value)"], files: ["/tmp/a.jpg"]))
    }

    @Test func aFilenameCarryingALineBreakIsRoutedToTheOneShot() {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["/tmp/we\nird.jpg"]))
    }

    /// The `-` case: a name beginning with a dash is read as an option
    /// wherever it appears, which is why the one-shot separates with `--`.
    @Test func aFilenameBeginningWithADashIsRoutedToTheOneShot() {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["/tmp/x/-foo.jpg"]))
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["-foo.jpg"]))
    }

    /// The quiet one: `-@` strips leading and trailing whitespace from each
    /// line, so " /tmp/a.jpg" addresses a different file than the caller meant.
    @Test(arguments: [" /tmp/a.jpg", "/tmp/a.jpg ", "\t/tmp/a.jpg"])
    func aFilenameWithEdgeWhitespaceIsRoutedToTheOneShot(_ file: String) {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [file]))
    }
}

// MARK: - The tag plan (no binary needed)

struct MetadataWriterPlanTests {
    @Test func keywordsAreClearedBeforeTheyAreSetSoAssignmentReplaces() {
        let plan = MetadataWriter.plan(MetadataEdit(keywords: ["alpha", "beta"]),
                                       families: .all, options: WriteOptions())
        let keywordArguments = plan.writeArguments.filter { $0.hasPrefix("-MWG:Keywords") }
        #expect(keywordArguments == ["-MWG:Keywords=", "-MWG:Keywords=alpha", "-MWG:Keywords=beta"])
    }

    @Test func everyLogicalFieldIsWrittenAcrossFamiliesNotJustOne() {
        let edit = MetadataEdit(artist: "Jane", copyright: "(c)", description: "d",
                                keywords: ["k"], gps: GPSCoordinate(latitude: 1, longitude: 2),
                                rating: 3, label: "Red")
        let plan = MetadataWriter.plan(edit, families: .all, options: WriteOptions())
        let arguments = plan.writeArguments
        #expect(arguments.contains("-MWG:Description=d"))
        #expect(arguments.contains("-MWG:Creator=Jane"))
        #expect(arguments.contains("-MWG:Copyright=(c)"))
        #expect(arguments.contains("-MWG:Rating=3"))
        #expect(arguments.contains("-XMP-xmp:Label=Red"))
        // Both GPS families, or the two disagree about the hemisphere.
        #expect(arguments.contains("-EXIF:GPSLatitudeRef=N"))
        #expect(arguments.contains("-EXIF:GPSLongitudeRef=E"))
        #expect(arguments.contains { $0.hasPrefix("-XMP-exif:GPSLatitude=") })
        // Keeps every later MWG reader from declaring the IPTC block stale.
        #expect(arguments.contains("-IPTCDigest=new"))
    }

    @Test func southernAndWesternHemispheresGetTheRightReferences() {
        let edit = MetadataEdit(gps: GPSCoordinate(latitude: -33.8688, longitude: -70.6693))
        let arguments = MetadataWriter.plan(edit, families: .all,
                                            options: WriteOptions()).writeArguments
        #expect(arguments.contains("-EXIF:GPSLatitudeRef=S"))
        #expect(arguments.contains("-EXIF:GPSLongitudeRef=W"))
        // EXIF carries an unsigned magnitude; XMP carries the sign.
        #expect(arguments.contains("-EXIF:GPSLatitude=33.8688"))
        #expect(arguments.contains("-XMP-exif:GPSLatitude=-33.8688"))
    }

    /// A sidecar is an XMP file: EXIF-group directives have nowhere to land, so
    /// planning them would ask exiftool for something it cannot do and then
    /// verify a tag that can never be there.
    @Test func aSidecarPlanCarriesNoEXIFDirectives() {
        let capture = CaptureTime(date: Date(), offset: "+00:00", subSeconds: "250")
        let edit = MetadataEdit(captureTime: capture,
                                gps: GPSCoordinate(latitude: 1, longitude: 2))
        let plan = MetadataWriter.plan(edit, families: .xmpOnly, options: WriteOptions())
        #expect(!plan.writeArguments.contains { $0.hasPrefix("-EXIF:") })
        #expect(!plan.expectations.contains { $0.key.hasPrefix("GPS:") })
        #expect(plan.expectations.contains { $0.key == "XMP-exif:GPSLatitude" })
    }

    /// GIF is written in place but has nowhere to put an EXIF block. Planning
    /// `-EXIF:*` for it made every GIF edit carrying a capture time or a
    /// position fail its own verification and roll back a write that had
    /// actually stored everything a GIF can store.
    @Test func aGIFIsPlannedForXMPOnlyEvenThoughItIsWrittenInPlace() {
        #expect(MetadataWriter.TagFamilies.of(.gif) == .xmpOnly)
        for kind in [MediaKind.jpeg, .png, .webp, .heic, .tiff, .psd] {
            #expect(MetadataWriter.TagFamilies.of(kind) == .all, "\(kind) should carry EXIF")
        }

        let capture = CaptureTime(date: Date(), offset: "+00:00")
        let edit = MetadataEdit(captureTime: capture,
                                gps: GPSCoordinate(latitude: 1, longitude: 2))
        let plan = MetadataWriter.plan(edit, families: .xmpOnly, options: WriteOptions())
        #expect(!plan.writeArguments.contains { $0.hasPrefix("-EXIF:") })
        #expect(!plan.expectations.contains { $0.key.hasPrefix("GPS:") })
        #expect(!plan.expectations.contains { $0.key.hasPrefix("ExifIFD:") })
        #expect(!plan.expectations.contains { $0.key.hasPrefix("Composite:") })
    }

    @Test func preserveModificationTimeAddsDashP() {
        let plain = MetadataWriter.plan(MetadataEdit(rating: 1), families: .all,
                                        options: WriteOptions())
        #expect(!plain.writeArguments.contains("-P"))
        let preserving = MetadataWriter.plan(
            MetadataEdit(rating: 1), families: .all,
            options: WriteOptions(preserveModificationTime: true))
        #expect(preserving.writeArguments.contains("-P"))
    }

    /// A cleared field must verify as *absent*, not as the empty string —
    /// exiftool removes the tag rather than storing "".
    @Test func clearingAFieldExpectsTheTagToBeGone() {
        let plan = MetadataWriter.plan(MetadataEdit(description: ""), families: .all,
                                       options: WriteOptions())
        #expect(plan.expectations.contains(
            MetadataWriter.Expectation(argument: "-MWG:Description",
                                       key: "MWG:Description", expected: .absent)))
    }

    @Test func aOneElementKeywordListReadsBackAsABareString() {
        // exiftool renders a single-valued list tag as a scalar, so the
        // comparison has to accept both shapes or every one-keyword write is
        // reported as a verification failure and rolled back.
        #expect(MetadataWriter.matches(.list(["alpha"]), "alpha"))
        #expect(MetadataWriter.matches(.list(["alpha", "beta"]), ["alpha", "beta"]))
        #expect(!MetadataWriter.matches(.list(["alpha"]), "beta"))
        #expect(!MetadataWriter.matches(.list(["alpha"]), nil))
        #expect(MetadataWriter.matches(.absent, nil))
        #expect(!MetadataWriter.matches(.absent, "x"))
    }

    @Test func sidecarPathReplacesTheExtension() {
        #expect(MetadataWriter.sidecarURL(for: URL(fileURLWithPath: "/p/IMG_0001.CR2")).path
            == "/p/IMG_0001.xmp")
        #expect(MetadataWriter.sidecarURL(for: URL(fileURLWithPath: "/p/-foo.dng")).path
            == "/p/-foo.xmp")
    }
}

// MARK: - Backup and restore (no binary needed)

struct MetadataWriteRestoreTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    @Test func restoringPutsTheOriginalBytesBackAndRemovesTheBackup() throws {
        let file = tree.root.appendingPathComponent("a.jpg")
        let backup = tree.root.appendingPathComponent("a.jpg_original")
        try Data("half-written".utf8).write(to: file)
        try Data("the original".utf8).write(to: backup)

        try MetadataWriter.restore(backup: backup, to: file, created: false, tags: ["X"])

        #expect(try Data(contentsOf: file) == Data("the original".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    /// A sidecar exiftool had to *create* has no `_original` to restore from,
    /// so undoing the write means deleting the file it made. Without this the
    /// failure leaves a half-written sidecar next to the RAW forever.
    @Test func restoringACreatedSidecarDeletesIt() throws {
        let sidecar = tree.root.appendingPathComponent("a.xmp")
        try Data("<x:xmpmeta/>".utf8).write(to: sidecar)

        try MetadataWriter.restore(backup: nil, to: sidecar, created: true, tags: ["X"])

        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func restoringAPreexistingFileWithNoBackupLeavesItAlone() throws {
        let file = tree.root.appendingPathComponent("a.jpg")
        try Data("untouched".utf8).write(to: file)
        try MetadataWriter.restore(backup: nil, to: file, created: false, tags: ["X"])
        #expect(try Data(contentsOf: file) == Data("untouched".utf8))
    }
}

// MARK: - Round trips against the real exiftool

@Suite(.serialized)
struct MetadataWriterRoundTripTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    private func exiftoolRead(_ url: URL, _ tags: [String]) throws -> [String: Any] {
        guard let path = MetadataWriter.availability.executablePath else {
            throw FixtureError.missing("exiftool")
        }
        let runner = ExiftoolRunner(executable: path)
        defer { runner.shutdown() }
        let run = try runner.run(arguments: ["-j", "-G1", "-n", "-s", "-a"] + tags,
                                 files: [url.path])
        return try MetadataWriter.parseJSON(run.stdout)
    }

    private var everyField: MetadataEdit {
        var components = DateComponents()
        components.year = 2021; components.month = 7; components.day = 8
        components.hour = 9; components.minute = 10; components.second = 11
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let capture = CaptureTime(date: calendar.date(from: components)!,
                                  offset: "-04:00", subSeconds: "250")
        return MetadataEdit(captureTime: capture,
                            artist: "Jane Doe",
                            copyright: "(c) 2021 Jane Doe",
                            description: "A caption with an accent: café",
                            keywords: ["alpha", "beta"],
                            gps: GPSCoordinate(latitude: 41.878100, longitude: -87.629800),
                            rating: 4,
                            label: "Red")
    }

    /// The acceptance criterion, in one test: every field written, then read
    /// back by exiftool *and* by ImageIO, with the three tag families each
    /// carrying the value. Writing only XMP is the failure mode this exists to
    /// catch, and it is invisible to a test that reads back through the same
    /// composite tag it wrote.
    @Test(needsExiftool) func everyFieldRoundTripsThroughAllThreeFamilies() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "write failed: \(String(describing: outcomes[0].error))")

        // --- exiftool, per family ---
        let tags = ["-IFD0:ImageDescription", "-IPTC:Caption-Abstract", "-XMP-dc:Description",
                    "-IFD0:Artist", "-IPTC:By-line", "-XMP-dc:Creator",
                    "-IFD0:Copyright", "-IPTC:CopyrightNotice", "-XMP-dc:Rights",
                    "-IPTC:Keywords", "-XMP-dc:Subject",
                    "-ExifIFD:DateTimeOriginal", "-ExifIFD:OffsetTimeOriginal",
                    "-IPTC:DateCreated", "-XMP-photoshop:DateCreated",
                    "-XMP-xmp:Rating", "-XMP-xmp:Label",
                    "-GPS:GPSLatitude", "-GPS:GPSLatitudeRef",
                    "-GPS:GPSLongitude", "-GPS:GPSLongitudeRef",
                    "-XMP-exif:GPSLatitude", "-XMP-exif:GPSLongitude"]
        let read = try exiftoolRead(url, tags)

        for key in ["IFD0:ImageDescription", "IPTC:Caption-Abstract", "XMP-dc:Description"] {
            #expect(read[key] as? String == "A caption with an accent: café",
                    "\(key) disagrees: \(String(describing: read[key]))")
        }
        for key in ["IFD0:Artist", "IPTC:By-line", "XMP-dc:Creator"] {
            #expect(read[key] as? String == "Jane Doe", "\(key) disagrees")
        }
        for key in ["IFD0:Copyright", "IPTC:CopyrightNotice", "XMP-dc:Rights"] {
            #expect(read[key] as? String == "(c) 2021 Jane Doe", "\(key) disagrees")
        }
        for key in ["IPTC:Keywords", "XMP-dc:Subject"] {
            #expect(read[key] as? [String] == ["alpha", "beta"], "\(key) disagrees")
        }
        #expect(read["ExifIFD:DateTimeOriginal"] as? String == "2021:07:08 09:10:11")
        #expect(read["ExifIFD:OffsetTimeOriginal"] as? String == "-04:00")
        #expect(read["IPTC:DateCreated"] as? String == "2021:07:08")
        #expect((read["XMP-photoshop:DateCreated"] as? String)?.hasPrefix("2021:07:08 09:10:11")
            == true)
        #expect((read["XMP-xmp:Rating"] as? NSNumber)?.intValue == 4)
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["GPS:GPSLatitudeRef"] as? String == "N")
        #expect(read["GPS:GPSLongitudeRef"] as? String == "W")
        // EXIF stores the magnitude; XMP stores the sign. Both must agree on
        // the actual place.
        #expect(abs(((read["GPS:GPSLongitude"] as? NSNumber)?.doubleValue ?? 0) - 87.6298) < 1e-6)
        #expect(abs(((read["XMP-exif:GPSLongitude"] as? NSNumber)?.doubleValue ?? 0) + 87.6298)
            < 1e-6)

        // --- ImageIO, the app's own reader ---
        let tiff = ImageIOProbe.tiff(url)
        #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String
            == "A caption with an accent: café")
        #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(tiff[kCGImagePropertyTIFFCopyright] as? String == "(c) 2021 Jane Doe")

        let iptc = ImageIOProbe.iptc(url)
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["alpha", "beta"])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
            == "A caption with an accent: café")

        let gps = ImageIOProbe.gps(url)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "W")

        // And the capture instant, through the reader the indexer uses.
        let metadata = try MetadataReader().read(url)
        #expect(metadata.captureOffset == "-04:00")
        #expect(metadata.captureTime == everyField.captureTime?.date)
    }

    /// Spec §9 lists JPEG, HEIC, TIFF and PNG as edited in place; WebP is here
    /// too because the image-hash tripwire below has to cover it.
    @Test(needsExiftool, arguments: [Fixtures.Format.jpeg, .png, .heic, .tiff, .gif, .psd])
    func writesInPlaceForEveryNonRAWContainer(_ format: Fixtures.Format) async throws {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.\(format.ext)"), format: format)
        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "\(format.ext) write failed: \(String(describing: outcomes[0].error))")
        #expect(outcomes[0].success?.target == .inPlace)
        // Nothing beside the file itself: the backup is removed on commit.
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords",
                                          "-XMP-xmp:Label", "-MWG:DateTimeOriginal"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["MWG:Keywords"] as? [String] == ["alpha", "beta"])
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["MWG:DateTimeOriginal"] as? String == "2021:07:08 09:10:11.250-04:00")
        // Whatever the container, the write is verified before it commits, so
        // a format that silently dropped a field would have failed above.
    }

    @Test(needsExiftool) func writesInPlaceForWebP() async throws {
        let source = try Fixtures.url("simple.webp")
        let url = tree.root.appendingPathComponent("a.webp")
        try FileManager.default.copyItem(at: source, to: url)

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "webp write failed: \(String(describing: outcomes[0].error))")
        let read = try exiftoolRead(url, ["-MWG:Description", "-XMP-xmp:Label"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["XMP-xmp:Label"] as? String == "Red")
    }

    /// **The tripwire** (HANDOFF §6). `image_hash` exists precisely so that a
    /// metadata edit does not invalidate duplicate detection. Every rule in
    /// `Hashing/` was verified against an exiftool round-trip by hand during
    /// design; this is the first time the app performs one, and the first time
    /// it is checked automatically. If this fails, the format's denylist or
    /// allowlist is wrong — that is a bug to file, not to paper over by
    /// loosening the rule.
    @Test(needsExiftool, arguments: ["jpg", "png", "webp", "heic"])
    func postWriteImageHashEqualsPreWriteImageHash(_ ext: String) async throws {
        let url = tree.root.appendingPathComponent("a.\(ext)")
        switch ext {
        case "jpg": try Fixtures.writeImage(to: url, format: .jpeg)
        case "png": try Fixtures.writeImage(to: url, format: .png)
        case "heic": try Fixtures.writeImage(to: url, format: .heic)
        default: try FileManager.default.copyItem(at: Fixtures.url("simple.webp"), to: url)
        }
        let mediaType = try #require(MediaType.forExtension(ext))
        let before = try FileHasher().hashes(for: url, mediaType: mediaType)
        try #require(before.imageHash != nil, "\(ext) fixture has no image hash to compare")

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "\(ext) write failed: \(String(describing: outcomes[0].error))")

        let after = try FileHasher().hashes(for: url, mediaType: mediaType)
        #expect(after.imageHash == before.imageHash,
                "image_hash moved for \(ext): the \(mediaType.imageHashKind ?? "?") rule is wrong")
        // The content hash *must* change; the bytes did.
        #expect(after.contentHash != before.contentHash)
        // And the writer reports the same thing it just proved.
        #expect(outcomes[0].success?.rehash?.imageHash == before.imageHash)
        #expect(outcomes[0].success?.rehash?.contentHash == after.contentHash)
        // A moved image_hash is a *failure* now, so the `#require` above is
        // itself the tripwire: this write could not have succeeded if the
        // format's rule had let the hash drift.
    }

    /// Spec §9, constraint 2. The RAW container is never opened for writing —
    /// that is where files get corrupted — so the edit goes to a sidecar and
    /// the container's `content_hash` is untouched.
    @Test(needsExiftool) func rawGetsASidecarAndTheContainerIsUntouched() async throws {
        // A real TIFF under a RAW extension: `MediaType` classifies `.dng` as
        // `.raw`, and the sidecar path never reads the container, so the
        // container's only job here is to have stable bytes to compare.
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0001.dng"), format: .tiff)
        try #require(MediaType.forExtension("dng")?.kind == .raw)
        let mediaType = try #require(MediaType.forExtension("dng"))
        let before = try FileHasher().hashes(for: container, mediaType: mediaType)

        let sidecar = tree.root.appendingPathComponent("IMG_0001.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [container])
        try #require(outcomes[0].error == nil,
                     "raw write failed: \(String(describing: outcomes[0].error))")
        #expect(outcomes[0].success?.target == .sidecar(sidecar))
        #expect(outcomes[0].success?.rehash == nil)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let after = try FileHasher().hashes(for: container, mediaType: mediaType)
        #expect(after.contentHash == before.contentHash,
                "the RAW container was modified by a sidecar write")

        let read = try exiftoolRead(sidecar, ["-MWG:Description", "-MWG:Keywords",
                                              "-MWG:Creator", "-XMP-xmp:Label",
                                              "-MWG:DateTimeOriginal", "-XMP-exif:GPSLatitude"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["MWG:Keywords"] as? [String] == ["alpha", "beta"])
        #expect(read["MWG:Creator"] as? String == "Jane Doe")
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["MWG:DateTimeOriginal"] as? String == "2021:07:08 09:10:11.250-04:00")
    }

    @Test(needsExiftool) func aSecondSidecarWriteUpdatesTheExistingFile() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0002.dng"), format: .tiff)
        let writer = MetadataWriter()
        _ = await writer.write(MetadataEdit(description: "first"), to: [container])
        let outcomes = await writer.write(MetadataEdit(description: "second"), to: [container])
        try #require(outcomes[0].error == nil)

        let sidecar = tree.root.appendingPathComponent("IMG_0002.xmp")
        let read = try exiftoolRead(sidecar, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == "second")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path + "_original"))
    }

    /// A format with no `image_hash` rule loses its duplicate grouping to the
    /// `content_hash` this write just invalidated. That is acceptable, but the
    /// writer must say so rather than let the inspector pretend the edit costs
    /// the same as one on a format that does have a rule.
    ///
    /// This was HEIC until the HEIC rule landed; it is now TIFF, GIF and PSD.
    /// The HEIC arm below is the regression guard for that change: a warning
    /// that keeps firing for a format that has since gained a hash is a lie the
    /// inspector would repeat.
    @Test(needsExiftool, arguments: [Fixtures.Format.tiff, .gif, .psd])
    func aFormatWithNoImageHashRuleSaysSo(_ format: Fixtures.Format) async throws {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("nohash.\(format.ext)"), format: format)
        let kind = try #require(MediaType.forExtension(format.ext)).kind
        try #require(MediaType.forExtension(format.ext)?.imageHashKind == nil,
                     "\(format.ext) has gained an image-hash rule; move it to the tripwire test")

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 3), to: [url])
        try #require(outcomes[0].error == nil,
                     "\(format.ext) write failed: \(String(describing: outcomes[0].error))")
        #expect(outcomes[0].success?.rehash?.imageHash == nil)
        #expect(outcomes[0].success?.warnings
            .contains(.imageHashUnavailable(kind: kind.rawValue)) == true)
    }

    @Test(needsExiftool, arguments: [Fixtures.Format.jpeg, .png, .heic])
    func aFormatWithAnImageHashRuleDoesNotWarn(_ format: Fixtures.Format) async throws {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("hashed.\(format.ext)"), format: format)
        try #require(MediaType.forExtension(format.ext)?.imageHashKind != nil)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 3), to: [url])
        try #require(outcomes[0].error == nil)
        #expect(outcomes[0].success?.rehash?.imageHash != nil)
        #expect(outcomes[0].success?.warnings.contains { warning in
            if case .imageHashUnavailable = warning { return true }
            return false
        } == false, "\(format.ext) has an image hash and must not warn that it has none")
    }

    /// An empty value clears the field out of all three families, and must
    /// verify as *absent* — exiftool removes the tag rather than storing "".
    @Test(needsExiftool) func anEmptyValueClearsTheFieldEverywhere() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("clear.jpg"))
        let writer = MetadataWriter()
        _ = await writer.write(MetadataEdit(description: "set", keywords: ["k1", "k2"]),
                               to: [url])

        let cleared = await writer.write(MetadataEdit(description: "", keywords: []), to: [url])
        try #require(cleared[0].error == nil,
                     "clearing failed: \(String(describing: cleared[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords",
                                          "-IFD0:ImageDescription", "-IPTC:Caption-Abstract",
                                          "-XMP-dc:Description", "-IPTC:Keywords",
                                          "-XMP-dc:Subject"])
        for key in ["MWG:Description", "MWG:Keywords", "IFD0:ImageDescription",
                    "IPTC:Caption-Abstract", "XMP-dc:Description", "IPTC:Keywords",
                    "XMP-dc:Subject"] {
            #expect(read[key] == nil, "\(key) survived the clear: \(String(describing: read[key]))")
        }
    }

    /// Rating 0 is a *value*, not an absence — it is the bottom of the 0...5
    /// range, and a writer that treats it as "clear the tag" cannot express it.
    @Test(needsExiftool) func aRatingOfZeroIsWrittenRatherThanTreatedAsAbsent() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("zero.jpg"))
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 0), to: [url])
        try #require(outcomes[0].error == nil,
                     "rating 0 failed: \(String(describing: outcomes[0].error))")
        let read = try exiftoolRead(url, ["-MWG:Rating", "-XMP-xmp:Rating"])
        #expect((read["MWG:Rating"] as? NSNumber)?.intValue == 0)
        #expect((read["XMP-xmp:Rating"] as? NSNumber)?.intValue == 0)
    }

    // MARK: Hostile fixtures

    /// The two hostile cases at once: a RAW whose name begins with a dash, so
    /// the sidecar has to be *created* through the one-shot path.
    @Test(needsExiftool) func aDashNamedRAWGetsItsSidecarThroughTheOneShot() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("-raw.dng"), format: .tiff)
        let sidecar = tree.root.appendingPathComponent("-raw.xmp")
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [sidecar.path]))

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "dash raw"), to: [container])
        try #require(outcomes[0].error == nil,
                     "dash-named raw failed: \(String(describing: outcomes[0].error))")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let read = try exiftoolRead(sidecar, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == "dash raw")
    }

    /// A file the user made in Finder called `-foo.jpg`. Through `-stay_open`
    /// it is read as an option; through the one-shot it is separated by `--`.
    @Test(needsExiftool) func aFilenameBeginningWithADashRoundTrips() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("-foo.jpg"))
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [url.path]))

        let writer = MetadataWriter()
        let outcomes = await writer.write(
            MetadataEdit(description: "dash named", keywords: ["k"]), to: [url])
        try #require(outcomes[0].error == nil,
                     "hostile-name write failed: \(String(describing: outcomes[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords"])
        #expect(read["MWG:Description"] as? String == "dash named")
        #expect(read["MWG:Keywords"] as? String == "k")
    }

    /// A description containing a newline. Through `-stay_open` this is
    /// argument injection: exiftool would read the tail of the value as its
    /// next argument — here, a literal `-delete_original!`.
    ///
    /// The CRLF case is the one a caption pasted from Windows actually carries,
    /// and it is the case Swift's `Character` comparison misses, so it is
    /// exercised against the real binary rather than only against the routing
    /// predicate.
    @Test(needsExiftool, arguments: ["first line\n-delete_original!\nthird line",
                                     "windows\r\ncaption\r\n-delete_original!"])
    func aDescriptionContainingANewlineRoundTrips(_ hostile: String) async throws {
        let name = "b-\(hostile.utf8.count).jpg"
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent(name))
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: hostile), to: [url])
        try #require(outcomes[0].error == nil,
                     "hostile-value write failed: \(String(describing: outcomes[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == hostile)
        // The injected text must have been stored, not executed: the file is
        // still here and so is its neighbour.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(needsExiftool) func anOrdinaryWriteTakesTheStayOpenPathAndReusesIt() throws {
        let path = try #require(MetadataWriter.availability.executablePath)
        let runner = ExiftoolRunner(executable: path)
        defer { runner.shutdown() }

        let first = try runner.run(arguments: ["-ver"], files: [])
        #expect(first.route == .stayOpen)
        #expect(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("13")
            || first.stdout.contains("."))

        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("c.jpg"))
        let second = try runner.run(arguments: ["-j", "-s", "-MWG:Description"],
                                    files: [url.path])
        #expect(second.route == .stayOpen)

        let hostile = try Fixtures.writeImage(to: tree.root.appendingPathComponent("-d.jpg"))
        let third = try runner.run(arguments: ["-j", "-s", "-MWG:Description"],
                                   files: [hostile.path])
        #expect(third.route == .oneShot)
    }

    // MARK: Failure behaviour

    /// Spec §11: a batch never fails as a unit.
    @Test(needsExiftool) func aBatchReportsPerItemResults() async throws {
        let good = try Fixtures.writeImage(to: tree.root.appendingPathComponent("good.jpg"))
        let missing = tree.root.appendingPathComponent("gone.jpg")
        let unsupported = try tree.file("notes.txt")

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 2),
                                          to: [good, missing, unsupported])
        #expect(outcomes.count == 3)
        #expect(outcomes[0].error == nil)
        #expect(outcomes[1].error == .fileMissing(missing.path))
        #expect(outcomes[2].error == .unsupportedFormat("txt"))
    }

    /// Spec §9, constraint 3, end to end: a mismatch restores from the
    /// `_original` backup and reports a failure rather than leaving the
    /// half-written file in place.
    @Test(needsExiftool) func averificationMismatchRestoresTheOriginal() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("e.jpg"))
        let originalBytes = try Data(contentsOf: url)

        let writer = MetadataWriter()
        await writer.setVerificationOverride { _ in ["MWG:Description"] }
        let outcomes = await writer.write(MetadataEdit(description: "never lands"), to: [url])

        #expect(outcomes[0].error == .verificationFailed(["MWG:Description"]))
        #expect(try Data(contentsOf: url) == originalBytes,
                "a failed verification must leave the original bytes on disk")
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"),
                "the backup must not be left lying around")
    }

    /// The same, for a sidecar exiftool had to create: there is no `_original`,
    /// so the undo is deleting it.
    @Test(needsExiftool) func afailedSidecarVerificationRemovesTheCreatedSidecar() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0003.dng"), format: .tiff)
        let sidecar = tree.root.appendingPathComponent("IMG_0003.xmp")

        let writer = MetadataWriter()
        await writer.setVerificationOverride { _ in ["MWG:Description"] }
        let outcomes = await writer.write(MetadataEdit(description: "never lands"),
                                          to: [container])

        #expect(outcomes[0].error == .verificationFailed(["MWG:Description"]))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path),
                "a sidecar created for a write that failed verification must be removed")
    }

    @Test(needsExiftool) func preservesTheModificationTimeWhenAsked() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("f.jpg"))
        // Backdated so "unchanged" cannot be confused with "written just now".
        let then = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: then],
                                              ofItemAtPath: url.path)

        let writer = MetadataWriter()
        let outcomes = await writer.write(
            MetadataEdit(description: "kept"), to: [url],
            options: WriteOptions(preserveModificationTime: true))
        try #require(outcomes[0].error == nil)

        let mtime = try #require(outcomes[0].success?.rehash?.mtime)
        #expect(abs(mtime - then.timeIntervalSince1970) < 1)
    }

    @Test(needsExiftool) func doesNotPreserveTheModificationTimeByDefault() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("g.jpg"))
        let then = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: then],
                                              ofItemAtPath: url.path)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "moved on"), to: [url])
        try #require(outcomes[0].error == nil)
        let mtime = try #require(outcomes[0].success?.rehash?.mtime)
        #expect(mtime > then.timeIntervalSince1970 + 1)
    }

    // MARK: The index

    /// After a successful write the row carries the new `size`/`mtime` and the
    /// re-verified hashes, so tier 0 does not decide the file is stale and
    /// clear every hash on it — including the `phash`, which is still correct
    /// because no pixel moved.
    @Test(needsExiftool) func updatesTheIndexRowAfterASuccessfulWrite() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("h.jpg"))
        let store = try IndexStore.inMemory()
        let mediaType = try #require(MediaType.forExtension("jpg"))
        let before = try FileHasher().hashes(for: url, mediaType: mediaType)
        let stat = try FileManager.default.attributesOfItem(atPath: url.path)

        var record = FileRecord(
            id: nil, path: url.path, parentDir: url.deletingLastPathComponent().path,
            name: url.lastPathComponent, ext: "jpg",
            size: (stat[.size] as! NSNumber).int64Value,
            mtime: (stat[.modificationDate] as! Date).timeIntervalSince1970,
            device: 1, inode: 1, width: 64, height: 48,
            captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
            orientation: 1, contentHash: before.contentHash, imageHash: before.imageHash,
            imageHashKind: before.imageHashKind, phash: "abcdef0123456789",
            hashedAt: 100, indexedAt: 100)
        record.id = try store.upsert(record)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "indexed"), to: [url],
                                          updating: store)
        try #require(outcomes[0].error == nil)
        #expect(outcomes[0].success?.warnings.contains(.indexRowNotUpdated) == false)

        let row = try #require(try store.record(atPath: url.path))
        let rehash = try #require(outcomes[0].success?.rehash)
        #expect(row.size == rehash.size)
        #expect(row.mtime == rehash.mtime)
        #expect(row.contentHash == rehash.contentHash)
        #expect(row.contentHash != before.contentHash)
        #expect(row.imageHash == before.imageHash)
        // The perceptual hash survives: an EXIF edit moves no pixels.
        #expect(row.phash == "abcdef0123456789")
        #expect(try store.needsReindex(path: url.path, size: row.size, mtime: row.mtime) == false)
    }
}

// MARK: - Rollback safety

/// A hasher whose image hash changes between the pre-write and post-write call.
///
/// The real tripwire can only fire if a rule in `Hashing/` is wrong, and those
/// rules are binding — so the *reaction* to a moved hash is tested by moving it
/// artificially. The alternative is shipping the most consequential branch in
/// the writer with no test at all.
private struct DriftingHasher: FileHashing {
    let calls = LockBox(0)
    let real = FileHasher()

    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        let actual = try real.hashes(for: url, mediaType: mediaType)
        let n = calls.withLock { (count: inout Int) -> Int in count += 1; return count }
        // First call is the pre-write hash; every later one pretends the image
        // data moved.
        let image = n == 1 ? actual.imageHash : "drifted-\(n)"
        return FileHashes(contentHash: actual.contentHash, imageHash: image,
                          imageHashKind: actual.imageHashKind)
    }
}

@Suite(.serialized)
struct MetadataWriterRollbackTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    private func exiftoolRead(_ url: URL, _ tags: [String]) throws -> [String: Any] {
        guard let path = MetadataWriter.availability.executablePath else {
            throw FixtureError.missing("exiftool")
        }
        let runner = ExiftoolRunner(executable: path)
        defer { runner.shutdown() }
        let run = try runner.run(arguments: ["-j", "-G1", "-n", "-s", "-a"] + tags,
                                 files: [url.path])
        return try MetadataWriter.parseJSON(run.stdout)
    }

    /// **exiftool silently declines to overwrite an existing `_original`.**
    /// Measured on 13.55: with a stale backup present it still reports
    /// "1 image files updated" and exits 0, and the stale file is left alone.
    ///
    /// So a writer that stats the backup path *after* the write mistakes
    /// somebody else's leftover for its own rollback — and a verification
    /// failure then copies that leftover over the photo. A stale 22-byte text
    /// file becomes the user's 2 MB JPEG, and the API reports only
    /// "verification failed".
    @Test(needsExiftool) func aStaleBackupIsNeverMistakenForThisWritesRollback() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("stale.jpg"))
        let photoBytes = try Data(contentsOf: url)
        let backup = URL(fileURLWithPath: url.path + "_original")
        let staleBytes = Data("not a photo, just a leftover".utf8)
        try staleBytes.write(to: backup)

        let writer = MetadataWriter()
        await writer.setVerificationOverride { _ in ["MWG:Description"] }
        let outcomes = await writer.write(MetadataEdit(description: "never lands"), to: [url])

        #expect(try Data(contentsOf: url) == photoBytes,
                "the photo was overwritten with an unrelated stale backup")
        #expect(try Data(contentsOf: backup) == staleBytes,
                "a stale backup this write did not create must be left exactly as found")
        #expect(outcomes[0].error != nil)
    }

    /// The same leftover, on the happy path: it must not be deleted either.
    /// The commit step removes *this write's* backup, not any file that
    /// happens to sit at that path.
    @Test(needsExiftool) func aStaleBackupSurvivesASuccessfulWrite() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("stale2.jpg"))
        let backup = URL(fileURLWithPath: url.path + "_original")
        let staleBytes = Data("leftover from an interrupted run".utf8)
        try staleBytes.write(to: backup)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "lands fine"), to: [url])
        try #require(outcomes[0].error == nil,
                     "write failed: \(String(describing: outcomes[0].error))")

        #expect(try Data(contentsOf: backup) == staleBytes,
                "the stale backup was deleted or overwritten by a write that did not own it")
        let read = try exiftoolRead(url, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == "lands fine")
    }

    /// The tripwire is a *failure*, not a note nobody reads. A moved
    /// `image_hash` means duplicate detection would group this file wrongly,
    /// and duplicate detection deletes files — so the edit is rolled back and
    /// the user is told, rather than the app carrying on with a hash it has
    /// just proved is unreliable.
    @Test(needsExiftool) func aMovedImageHashFailsTheWriteAndRestoresTheFile() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("drift.jpg"))
        let originalBytes = try Data(contentsOf: url)

        let writer = MetadataWriter(hasher: DriftingHasher())
        let outcomes = await writer.write(MetadataEdit(description: "should roll back"),
                                          to: [url])

        guard case .imageHashChanged(let kind, _, let after)? = outcomes[0].error else {
            Issue.record("expected .imageHashChanged, got \(String(describing: outcomes[0].error))")
            return
        }
        #expect(kind == "jpeg-scan-v1")
        #expect(after.hasPrefix("drifted-"))
        #expect(try Data(contentsOf: url) == originalBytes,
                "a moved image_hash must roll the edit back, not keep it")
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))
    }

    /// The failure of the failure: verification failed, and the restore failed
    /// too, so what is on disk is the half-written file. This is the loudest
    /// case and the one a summary sheet must not report as an ordinary miss.
    @Test func restoreReportsFailureWhenItCannotPutTheOriginalBack() throws {
        let directory = try tree.directory("locked")
        let file = directory.appendingPathComponent("a.jpg")
        let backup = directory.appendingPathComponent("a.jpg_original")
        try Data("half-written".utf8).write(to: file)
        try Data("the original".utf8).write(to: backup)
        // Read and execute, but not write: the replace needs to create a
        // temporary file in this directory and cannot.
        try tree.chmod("locked", 0o500)

        #expect(throws: MetadataWriteError.self) {
            try MetadataWriter.restore(backup: backup, to: file, created: false, tags: ["X"])
        }
    }

    /// `-@` eats one leading space of a value. A legal caption that begins with
    /// whitespace would therefore read back short, fail verification, and get
    /// rolled back — a correct edit destroyed by the transport.
    @Test(needsExiftool, arguments: ["  indented value", "\ttabbed value",
                                     "trailing space  "])
    func aValueWithEdgeWhitespaceRoundTripsExactly(_ value: String) async throws {
        let name = "ws-\(value.utf8.count)-\(abs(value.hashValue % 1000)).jpg"
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent(name))
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: value), to: [url])
        try #require(outcomes[0].error == nil,
                     "\(value.debugDescription) failed: \(String(describing: outcomes[0].error))")
        let read = try exiftoolRead(url, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == value)
    }

    /// A caption that spells the `-stay_open` ready sentinel. Matched anywhere
    /// in the stream it truncates the JSON read-back mid-object and leaves the
    /// rest in the pipe, desynchronising every later command on the session.
    @Test(needsExiftool) func aCaptionSpellingTheReadySentinelDoesNotTruncateTheReadBack()
        async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("sentinel.jpg"))
        let caption = "{ready}{ready0}{ready1}{ready2}{ready10}{readyerr1} and more text"
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: caption, rating: 5),
                                          to: [url])
        try #require(outcomes[0].error == nil,
                     "sentinel caption failed: \(String(describing: outcomes[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Rating"])
        #expect(read["MWG:Description"] as? String == caption)
        #expect((read["MWG:Rating"] as? NSNumber)?.intValue == 5)

        // And the session is still usable afterwards: a truncated read leaves
        // residue that desynchronises the *next* command, not this one.
        let second = await writer.write(MetadataEdit(description: "after"), to: [url])
        #expect(second[0].error == nil)
        let again = try exiftoolRead(url, ["-MWG:Description"])
        #expect(again["MWG:Description"] as? String == "after")
    }
}

// MARK: - Routing, second pass

struct ExiftoolValueRoutingTests {
    /// The token always begins with `-`, so a whole-token whitespace check only
    /// ever catches the trailing side. It is the *value* after `=` that the
    /// argfile parser trims.
    @Test(arguments: ["-MWG:Description=  indented", "-MWG:Description=\ttabbed",
                      "-MWG:Description=trailing ", "-XMP-xmp:Label= x "])
    func aValueWithEdgeWhitespaceIsRoutedToTheOneShot(_ argument: String) {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [argument], files: ["/tmp/a.jpg"]))
    }

    @Test(arguments: ["-MWG:Description=inner space is fine", "-MWG:Keywords=",
                      "-m", "-IPTCDigest=new", "-MWG:Rating=3"])
    func ordinaryArgumentsStayOnTheStayOpenPath(_ argument: String) {
        #expect(!ExiftoolRunner.requiresOneShot(arguments: [argument], files: ["/tmp/a.jpg"]))
    }
}

// MARK: - Sentinel anchoring

/// The nonce makes the sentinel unguessable; the anchoring makes it
/// unspellable. Both are needed, and a round-trip test alone cannot tell them
/// apart — with a nonce in place, an unanchored `contains` match still passes
/// every end-to-end test. So the anchoring is pinned directly.
struct PipeDrainSentinelTests {
    private func find(_ text: String, _ sentinel: String) -> Int? {
        PipeDrain.anchoredSentinel(in: Data(text.utf8), sentinel: Data(sentinel.utf8))
            .map { Data(text.utf8).distance(from: Data(text.utf8).startIndex, to: $0) }
    }

    @Test func matchesASentinelOnItsOwnLine() {
        #expect(find("[{\"a\":1}]\n{ready7}\n", "{ready7}") == 10)
    }

    @Test func matchesASentinelAtTheStartOfTheStream() {
        #expect(find("{ready7}\n", "{ready7}") == 0)
    }

    /// The defect: a tag value that spells the sentinel ends the read
    /// mid-object, truncating the JSON and leaving the remainder in the pipe to
    /// desynchronise the next command.
    @Test func ignoresASentinelEmbeddedInAValue() {
        #expect(find("[{\"Description\":\"{ready7} in a caption\"}]\n", "{ready7}") == nil)
    }

    @Test func skipsAnEmbeddedOccurrenceAndFindsTheRealOneAfterIt() {
        let stream = "[{\"d\":\"{ready7}\"}]\n{ready7}\n"
        #expect(find(stream, "{ready7}") == 19)
    }

    /// A sentinel split across two reads must not match until its trailing
    /// newline has actually arrived, or the read ends one byte early.
    @Test func waitsForTheTrailingNewline() {
        #expect(find("out\n{ready7}", "{ready7}") == nil)
        #expect(find("out\n{ready7}\n", "{ready7}") == 4)
    }

    /// A longer id must not be matched by a shorter one's sentinel.
    @Test func doesNotMatchADifferentCommandsSentinel() {
        #expect(find("out\n{ready71}\n", "{ready7}") == nil)
    }
}

// MARK: - Teardown must be bounded

/// A hasher that fails the *first* call — the pre-write one — and then returns
/// a deliberately different image hash. Models a mid-read I/O error on a flaky
/// external volume, which is this project's actual deployment.
private struct FailsFirstReadHasher: FileHashing {
    let calls = LockBox(0)
    let real = FileHasher()

    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        let n = calls.withLock { (count: inout Int) -> Int in count += 1; return count }
        if n == 1 { throw HashError.unreadable }
        let actual = try real.hashes(for: url, mediaType: mediaType)
        return FileHashes(contentHash: actual.contentHash, imageHash: "totally-different",
                          imageHashKind: actual.imageHashKind)
    }
}

@Suite(.serialized)
struct MetadataWriterTeardownTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    /// **Teardown must never block indefinitely.** `ExiftoolRunner.deinit` runs
    /// wherever the last reference is dropped — for an actor's stored property
    /// that is an arbitrary cooperative-pool thread — and `waitUntilExit` has no
    /// bound. It was sampled parked in a runloop for ten minutes with the
    /// exiftool child *already dead*: two `Process` objects reaped concurrently
    /// and Foundation missed the termination. A blocked cooperative thread does
    /// not come back.
    ///
    /// The race itself is rare (roughly one run in three for the reviewer, and
    /// it did not reproduce in sixty iterations here), so this pins the
    /// *property* instead: a child that traps SIGTERM and would otherwise sleep
    /// for 30 s must be dealt with in about a second. A reintroduced
    /// `waitUntilExit` fails this by taking the full 30 s.
    @Test func endingAProcessIsBoundedEvenWhenTheChildIgnoresSIGTERM() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let started = Date()
        let ended = ExiftoolRunner.endProcess(process, force: true,
                                              cooperative: 0.2, afterSignal: 0.4)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 5,
                "teardown must be bounded; it took \(elapsed)s against a 30s child")
        // SIGTERM is trapped, SIGKILL cannot be, so the escalation does finish
        // the job — which is why the escalation is there.
        #expect(ended, "escalation must reach SIGKILL when SIGTERM is ignored")
    }

    /// And it must not wait on a child that is already gone.
    ///
    /// Note what this test does *not* do: call `waitUntilExit()` to settle the
    /// child first. That is the very call under indictment, and using it here
    /// blocked a cooperative-pool thread on CI — with a three-core runner and
    /// several suites spawning processes at once, three such blocks starved the
    /// pool and 141 tests never ran at all. `endProcess` is bounded, so it is
    /// safe to use it to reach the state this test is about.
    @Test func endingAnAlreadyExitedProcessReturnsImmediately() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        #expect(ExiftoolRunner.endProcess(process), "/usr/bin/true should exit on its own")

        let started = Date()
        #expect(ExiftoolRunner.endProcess(process, cooperative: 5, afterSignal: 5))
        #expect(Date().timeIntervalSince(started) < 1,
                "a second call on an exited process must not wait")
    }

    /// The real-world path, exercised end to end: nothing calls `close()`, so
    /// every writer reaches teardown by being released on the cooperative pool.
    /// This does not reliably reproduce the race — it is a smoke test that the
    /// ordinary path stays quick.
    @Test(needsExiftool) func tearingDownWritersByReleaseIsBounded() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("td.jpg"))
        let source = url

        // Awaited, not waited on. A `DispatchSemaphore.wait` here would block
        // the very cooperative-pool thread whose starvation this suite exists
        // to prevent — and on a small runner, blocking to *check* for a hang is
        // how you cause one.
        let finished = await completes(within: 90) {
            for _ in 0..<6 {
                let a = MetadataWriter()
                let b = MetadataWriter()
                _ = await a.write(MetadataEdit(rating: 1), to: [source])
                _ = await b.write(MetadataEdit(rating: 2), to: [source])
                // Both drop here, on the cooperative pool.
            }
        }
        #expect(finished, "writer teardown blocked the cooperative pool")
    }
}

// MARK: - Failure paths must not lie about what happened

@Suite(.serialized)
struct MetadataWriteFailurePathTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    /// **A pre-write hash that cannot be read disables the tripwire.** With
    /// `try?` the comparison is skipped and the post-write hash — whatever it
    /// is — goes into the index with nothing to check it against. `image_hash`
    /// is what the duplicate view deletes on, so an unverifiable one must fail
    /// the item, not be recorded on trust.
    @Test(needsExiftool) func aPreWriteHashThatCannotBeReadFailsTheItem() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("unreadable.jpg"))
        let originalBytes = try Data(contentsOf: url)

        let writer = MetadataWriter(hasher: FailsFirstReadHasher())
        let outcomes = await writer.write(MetadataEdit(description: "x"), to: [url])

        #expect(outcomes[0].success == nil,
                "a write whose image hash cannot be verified must not report success")
        #expect(outcomes[0].error != nil)
        // Nothing was written, so nothing needs rolling back.
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))
    }

    /// Every error that follows a write must say whether the file was put back.
    /// Spec §11's summary sheet reports "what failed and why", and "verification
    /// failed" reads as "your file is fine" — which is false when there was no
    /// backup to restore from.
    @Test func everyErrorExplainsItself() {
        let errors: [MetadataWriteError] = [
            .exiftoolUnavailable("x"), .captureTimeRequiresTimeZone,
            .invalidTimeZoneOffset("+5"), .invalidSubSeconds("a"), .invalidRating(9),
            .invalidCoordinate(latitude: 91, longitude: 0), .nothingToWrite,
            .unsupportedFormat("txt"), .fileMissing("/a/b.jpg"), .exiftoolFailed("boom"),
            .verificationFailed(["MWG:Description"]),
            .restoreFailed(tags: ["MWG:Description"], reason: "denied"),
            .verificationFailedWithoutRollback(tags: ["MWG:Description"]),
            .backupPathOccupied("/a/b.jpg_original"),
            .imageHashChanged(kind: "jpeg-scan-v1", before: "a", after: "b"),
            .imageHashUnreadable("/a/b.jpg"),
        ]
        for error in errors {
            #expect(!error.explanation.isEmpty, "\(error) has no explanation")
            #expect(error.explanation.last == "." , "\(error) is not a sentence")
        }
        // The three-way distinction a summary sheet has to preserve.
        #expect(MetadataWriteError.verificationFailed(["a"]).explanation
            .localizedCaseInsensitiveContains("restored"))
        #expect(MetadataWriteError.verificationFailedWithoutRollback(tags: ["a"]).explanation
            .localizedCaseInsensitiveContains("no backup"))
        #expect(MetadataWriteError.restoreFailed(tags: ["a"], reason: "denied").explanation
            .localizedCaseInsensitiveContains("could not be restored"))
    }

    /// A rehash that fails *after* the write used to call `restore` directly
    /// and then report `exiftoolFailed`. `restore` is a silent no-op when there
    /// is no backup, so that path could leave the edited file on disk while
    /// reporting an error that implies it had been put back. Every post-write
    /// failure now goes through the same rollback, and says which of the three
    /// things actually happened.
    @Test(needsExiftool) func aRehashFailureAfterTheWriteRollsTheFileBack() async throws {
        struct FailsSecondReadHasher: FileHashing {
            let calls = LockBox(0)
            let real = FileHasher()
            func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
                let n = calls.withLock { (count: inout Int) -> Int in count += 1; return count }
                if n >= 2 { throw HashError.unreadable }
                return try real.hashes(for: url, mediaType: mediaType)
            }
        }
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("rehashfail.jpg"))
        let originalBytes = try Data(contentsOf: url)

        let writer = MetadataWriter(hasher: FailsSecondReadHasher())
        let outcomes = await writer.write(MetadataEdit(description: "rolled back"), to: [url])

        #expect(outcomes[0].error == .imageHashUnreadable(url.path))
        #expect(try Data(contentsOf: url) == originalBytes,
                "a post-write rehash failure must roll the edit back")
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))
    }

    /// A leftover stash from a killed run must not accumulate beside the photo,
    /// and must not be mistaken for anything else.
    @Test(needsExiftool) func aLeftoverStashIsSweptOnTheNextWrite() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("swept.jpg"))
        let leftover = URL(fileURLWithPath:
            url.path + "_original.lightbox-stash-DEADBEEF-0000-0000-0000-000000000000")
        try Data("orphaned by a killed run".utf8).write(to: leftover)
        // A file that merely looks similar must survive.
        let bystander = URL(fileURLWithPath: url.path + "_original.mine")
        try Data("not ours".utf8).write(to: bystander)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "sweeps"), to: [url])
        try #require(outcomes[0].error == nil)

        #expect(!FileManager.default.fileExists(atPath: leftover.path),
                "an orphaned stash must be swept, not left to accumulate")
        #expect(FileManager.default.fileExists(atPath: bystander.path),
                "the sweep must only match its own suffix pattern")
        #expect(outcomes[0].success?.warnings.contains(
            .sweptOrphanedBackup(leftover.lastPathComponent)) == true)
    }

    /// A row the store cannot produce means the index was *not* updated, and
    /// silently swallowing that is how an index drifts out of step with disk.
    @Test(needsExiftool) func anAbsentIndexRowIsReportedNotSwallowed() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("norow.jpg"))
        let store = try IndexStore.inMemory()   // nothing indexed at this path

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 1), to: [url], updating: store)
        try #require(outcomes[0].error == nil)
        #expect(outcomes[0].success?.warnings.contains(.indexRowNotUpdated) == true,
                "a missing row must be reported, not silently skipped")
    }

    /// Cancelling a batch stops it; the items already written stay written.
    @Test(needsExiftool) func aCancelledBatchStopsAndKeepsCompletedItems() async throws {
        var urls: [URL] = []
        for index in 0..<6 {
            urls.append(try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("batch\(index).jpg")))
        }
        let writer = MetadataWriter()
        let progress = LockBox([Int]())

        let task = Task { () -> [WriteOutcome] in
            await writer.write(MetadataEdit(description: "batched"), to: urls) { done, total in
                progress.withLock { (seen: inout [Int]) in seen.append(done) }
                #expect(total == 6)
            }
        }
        let outcomes = await task.value
        #expect(outcomes.count == 6)
        // The callback fires once per item, in order.
        #expect(progress.withLock { (seen: inout [Int]) in seen } == [1, 2, 3, 4, 5, 6])
    }

    @Test(needsExiftool) func aCancelledBatchReportsCancellationForTheRest() async throws {
        var urls: [URL] = []
        for index in 0..<40 {
            urls.append(try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("cancel\(index).jpg")))
        }
        let writer = MetadataWriter()
        let started = LockBox(false)

        let task = Task { () -> [WriteOutcome] in
            await writer.write(MetadataEdit(description: "cancelled"), to: urls) { done, _ in
                if done == 1 { started.withLock { (flag: inout Bool) in flag = true } }
            }
        }
        // Wait for the first item to land, then cancel mid-batch.
        for _ in 0..<300 where !started.withLock({ (flag: inout Bool) in flag }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let outcomes = await task.value

        #expect(outcomes.count == 40)
        #expect(outcomes[0].error == nil, "the item already done stays done")
        #expect(outcomes.contains { $0.error == .cancelled },
                "the rest must report cancellation rather than being written")
    }
}
