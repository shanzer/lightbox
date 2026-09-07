import Testing
import Foundation

/// **The CI hang, in the test target's own helpers.**
///
/// #18 bounded every wait in the code the app ships. The two helpers the *test*
/// target used to spawn children with — the exiftool skip guard and the `sips`
/// re-encode — still called `waitUntilExit()`, which has no bound. On the
/// three-core `macos-26` runner a blocked wait parks a cooperative-pool thread,
/// and three of them starve the pool completely: 141 tests never ran and the job
/// had to be killed after fourteen minutes.
///
/// `BoundedProcess` is the answer for both. This is its regression test, and it
/// is deliberately shaped like the one #18 added for `ExiftoolLocator`: a stub
/// child that never exits must produce a *result* — quickly — not a hang.
struct BoundedProcessTests {
    @Test func aChildThatNeverExitsTimesOutRatherThanHanging() {
        let started = Date()
        let outcome = BoundedProcess.run("/bin/sh", ["-c", "sleep 60"], timeout: 0.75)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2, "the wait must be bounded; it took \(elapsed)s")
        #expect(outcome.timedOut)
        #expect(!outcome.ok, "a child that never answered must not be reported as success")
    }

    /// The bound must not be paid by a child that answers promptly, and the
    /// output has to survive the drain — otherwise a test asserting on stdout
    /// would pass vacuously.
    @Test func aChildThatExitsIsReportedWithItsOutputAndStatus() {
        let outcome = BoundedProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 0"])
        #expect(outcome.ok)
        #expect(!outcome.timedOut)
        #expect(outcome.status == 0)
        #expect(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "out")
        #expect(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "err")
    }

    @Test func aNonZeroExitIsNotSuccess() {
        let outcome = BoundedProcess.run("/bin/sh", ["-c", "exit 3"])
        #expect(!outcome.ok)
        #expect(outcome.status == 3)
    }

    /// A missing binary is a `false`, not a crash: the helper stands in for
    /// tools that may simply not be installed on the runner.
    @Test func aBinaryThatCannotBeLaunchedIsNotSuccess() {
        let outcome = BoundedProcess.run("/nonexistent/bin/nope", [])
        #expect(!outcome.ok)
        #expect(!outcome.launched)
    }
}
