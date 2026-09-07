import Foundation
@testable import LightboxCore

/// Whether the tests that need the real exiftool can run.
///
/// The guard consults `MetadataWriter.availability` — the same lookup the writer
/// performs, as CONTRIBUTING requires: "its skip guard must consult the same
/// path the code under test reads". It used to fork its own `/usr/bin/env
/// exiftool -ver` and wait on it without a deadline, which was both a second
/// opinion about `PATH` and the CI-hang hazard #18 removed everywhere else.
/// Routing it through the locator fixes both at once: that probe is bounded
/// (`ExiftoolLocator.versionProbeTimeout`) and its answer is cached, so a suite
/// full of gated tests forks one probe rather than one per test.
var exiftoolAvailable: Bool { MetadataWriter.availability.isAvailable }

/// Runs exiftool if it is usable; returns false when it is not, so the suite
/// stays green on a machine without it.
///
/// Bounded through `BoundedProcess`: never `waitUntilExit()`.
@discardableResult
func exiftool(_ args: [String]) -> Bool {
    guard case .available(let path, _) = MetadataWriter.availability else { return false }
    return BoundedProcess.run(path, args).ok
}
