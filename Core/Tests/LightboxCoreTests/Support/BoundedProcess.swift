import Foundation
@testable import LightboxCore

/// Runs a child process to completion **against a deadline**, for the handful of
/// tests that need a real external tool.
///
/// **Never `waitUntilExit()`, never `readDataToEndOfFile()`.** Both are
/// unbounded, and a swift-testing test body runs on a cooperative-pool thread: a
/// blocked one never comes back, and on the three-core `macos-26` runner a few
/// of them starve the pool so that unrelated tests stop being scheduled at all.
/// That is exactly the fourteen-minute CI hang #18 diagnosed — three unbounded
/// waits, 141 tests never reported.
///
/// The bound is the same machinery the writer uses (`PipeDrain` for both
/// descriptors at once, so neither can fill its 64 KB buffer while this side
/// waits on the other; `ExiftoolRunner.endProcess` for the bounded reap,
/// escalating to SIGKILL), reached through `@testable import`. A wedged child
/// therefore becomes a *failed expectation in a named test*, in under a second,
/// rather than a suite that stops responding.
enum BoundedProcess {
    struct Outcome {
        /// Whether the binary could be started at all — a tool that is simply
        /// not installed lands here rather than throwing.
        var launched: Bool
        /// Whether the child was confirmed gone. `endProcess` promises bounded,
        /// not successful; an unconfirmed exit is not treated as one.
        var exited: Bool
        var timedOut: Bool
        var status: Int32
        var stdout: String
        var stderr: String

        var ok: Bool { launched && exited && !timedOut && status == 0 }
    }

    /// Generous for the tools this runs (`exiftool -ver`, one `sips`
    /// re-encode), and short enough that a wedged child is a red test rather
    /// than a stalled suite. Not a number to tune downward to make something
    /// pass: it exists because these waits used to have no bound at all.
    static let defaultTimeout: TimeInterval = 30

    static func run(_ executable: String, _ arguments: [String],
                    timeout: TimeInterval = BoundedProcess.defaultTimeout) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        // A tool that wants a tty must fail rather than block on one.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return Outcome(launched: false, exited: false, timedOut: false,
                           status: -1, stdout: "", stderr: "")
        }

        let deadline = Date().addingTimeInterval(timeout)
        let drained: PipeDrain.Result
        do {
            drained = try PipeDrain.readToEnd(
                first: out.fileHandleForReading.fileDescriptor,
                second: err.fileHandleForReading.fileDescriptor,
                deadline: deadline)
        } catch {
            // A timed-out child must not be left running: it may still hold the
            // file it was rewriting open, and the next test will find it there.
            ExiftoolRunner.endProcess(process, force: true)
            return Outcome(launched: true, exited: false, timedOut: true,
                           status: -1, stdout: "", stderr: "")
        }

        // Both pipes are at EOF, so the child has finished — but Foundation has
        // been observed to miss a termination anyway (see `endProcess`), so the
        // reap is bounded too, and an exit status is only read from a process
        // known to have exited.
        let exited = ExiftoolRunner.endProcess(process)
        return Outcome(launched: true, exited: exited, timedOut: false,
                       status: exited ? process.terminationStatus : -1,
                       stdout: String(decoding: drained.first, as: UTF8.self),
                       stderr: String(decoding: drained.second, as: UTF8.self))
    }
}
