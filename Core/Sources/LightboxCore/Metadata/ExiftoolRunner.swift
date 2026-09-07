import Foundation

/// The result of one exiftool invocation.
struct ExiftoolRun {
    var stdout: String
    var stderr: String
    /// True when exiftool exited 0 (one-shot) or wrote nothing that looks like
    /// an error (`-stay_open`, which reports no exit status per command).
    var ok: Bool
    /// Which route the invocation took. Tests assert on this, because "the
    /// hostile input was handled" and "the hostile input was handled *by the
    /// one-shot path*" are different claims.
    var route: Route

    enum Route: Equatable { case stayOpen, oneShot }
}

enum ExiftoolRunnerError: Error, CustomStringConvertible {
    case launchFailed(String)
    case processDied(String)
    case timedOut(Double)

    var description: String {
        switch self {
        case .launchFailed(let why): "could not launch exiftool: \(why)"
        case .processDied(let what): "exiftool exited unexpectedly (\(what))"
        case .timedOut(let seconds): "exiftool did not answer within \(seconds)s"
        }
    }
}

/// Runs exiftool, over a long-lived `-stay_open` process where that is safe and
/// over a one-shot `Process` where it is not.
///
/// **Why two routes** — spec §9, constraint 4. The `-stay_open`/`-@ -` argument
/// protocol is newline-delimited: exiftool reads one argument per line and
/// strips surrounding whitespace. A tag value or a path containing `\n` or `\r`
/// therefore does not merely fail, it *injects arguments* — a description of
/// `"x\n-delete_original!"` would be read as a value and then as a command.
/// Leading or trailing whitespace in a path is the quieter version of the same
/// bug: the line is silently trimmed and a different file is addressed. And a
/// filename beginning with `-` is read as an option wherever it appears.
///
/// All of those are detected up front and routed to a one-shot `Process`, where
/// arguments are passed as an `argv` array — no delimiter to escape — with `--`
/// separating options from filenames. The fast path stays fast for the 99.9%
/// of files that are ordinary; the hostile 0.1% pays one fork.
///
/// Not `Sendable` on purpose: it owns a `Process` and two pipe descriptors, and
/// is only ever reached from inside `MetadataWriter`'s actor isolation.
final class ExiftoolRunner {
    /// How long one exiftool command may take before the `-stay_open` process
    /// is presumed wedged and killed. Generous: a write to a 200 MB file on a
    /// spun-down external drive is slow, but not minutes-slow.
    static let commandTimeout: TimeInterval = 120

    let executable: String

    private var session: StayOpenSession?
    private var nextCommandNumber = 1

    /// A per-runner random prefix for the `-stay_open` command numbers, so the
    /// ready sentinel cannot be predicted by whoever wrote the caption being
    /// stored. `-execute` only accepts digits — a non-numeric suffix produces
    /// no sentinel at all, measured on 13.55 — so the nonce is numeric.
    private let sentinelNonce = Int.random(in: 100_000_000...999_999_999)

    /// An empty exiftool config, so a `~/.ExifTool_config` that redefines tags
    /// cannot change what a verification read sees. Perl requires a config to
    /// evaluate true, hence `1;` rather than a zero-byte file — `-config
    /// /dev/null` works but prints "did not return a true value" to stderr on
    /// every single invocation, which would show up as a warning on every write.
    ///
    /// Best effort: if it cannot be created the runner simply does without,
    /// because this is hardening, not correctness.
    private let emptyConfig: URL?

    /// Options that must precede everything else on the command line.
    private var leadingArguments: [String] {
        guard let emptyConfig else { return [] }
        return ["-config", emptyConfig.path]
    }

    init(executable: String) {
        self.executable = executable
        // Written eagerly rather than lazily: a lazy var would let `deinit`
        // create the file only to delete it again on a runner that never ran
        // anything.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightbox-exiftool-\(UUID().uuidString).config")
        emptyConfig = (try? Data("1;\n".utf8).write(to: url)) == nil ? nil : url
    }

    deinit {
        session?.shutdown()
        if let emptyConfig { try? FileManager.default.removeItem(at: emptyConfig) }
    }

    /// Scalars that end a line in the `-@` protocol, plus NUL, which truncates
    /// the argument at the `execve` boundary instead.
    private static let forbiddenScalars: Set<Unicode.Scalar> = ["\n", "\r", "\0"]

    /// True when this argument list cannot safely cross the newline-delimited
    /// `-stay_open` protocol. See the type's doc comment.
    static func requiresOneShot(arguments: [String], files: [String]) -> Bool {
        for token in arguments + files {
            // Scanned as unicode scalars, not as `Character`s. Swift collapses
            // a CR-LF pair into one grapheme cluster that equals neither "\n"
            // nor "\r", so `token.contains("\n")` is *false* for "a\r\nb" — and
            // that is precisely the sequence a Windows-authored caption
            // carries. Checking characters here would let the one hostile value
            // most likely to occur in real data through to the newline-
            // delimited protocol.
            if token.unicodeScalars.contains(where: Self.forbiddenScalars.contains) {
                return true
            }
            if hasEdgeWhitespace(token) { return true }
            // An argument is `-TAG=VALUE`, and it is the VALUE the argfile
            // parser trims — measured on 13.55: `-MWG:Description=  indented`
            // comes back as " indented", one space short. Checking only the
            // whole token can never catch that, because the token always
            // begins with "-"; it only ever catches the trailing side. A legal
            // caption that starts with a space would otherwise read back
            // different from what was asked for, fail verification, and get a
            // correct edit rolled back.
            if let equals = token.firstIndex(of: "="),
               hasEdgeWhitespace(String(token[token.index(after: equals)...])) {
                return true
            }
        }
        for file in files {
            // The absolute paths this writer builds always start with "/", so
            // in practice this catches a relative path handed in by a future
            // caller. Checking the basename as well keeps the guard honest
            // about what the hazard actually is: a *name* that starts with a
            // dash, which is what a user can create in Finder.
            if file.hasPrefix("-") { return true }
            if (file as NSString).lastPathComponent.hasPrefix("-") { return true }
        }
        return false
    }

    /// True when the string begins or ends with a whitespace scalar. Deliberately
    /// broader than ASCII space and tab: routing something harmless to the
    /// one-shot costs one fork, while missing something costs a mangled value.
    private static func hasEdgeWhitespace(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              let last = text.unicodeScalars.last else { return false }
        let whitespace = CharacterSet.whitespacesAndNewlines
        return whitespace.contains(first) || whitespace.contains(last)
    }

    /// Ends `process` within a bounded time, escalating, and gives up rather
    /// than waiting forever.
    ///
    /// **Never `waitUntilExit()`.** This runs from `deinit`, which for an
    /// actor's stored property means an arbitrary cooperative-pool thread, and
    /// `waitUntilExit` has no bound. It was sampled parked in a runloop for ten
    /// minutes with the exiftool child *already dead*: two `Process` objects
    /// reaped concurrently and Foundation missed the termination. A blocked
    /// cooperative thread is not recoverable, so the contract here is "bounded",
    /// not "successful" — if the process cannot be confirmed gone, this gives up
    /// and returns false rather than holding the thread.
    ///
    /// Polling `isRunning` rather than waiting on it is the price of that
    /// bound, and it is only paid at teardown.
    ///
    /// - Returns: whether the process is known to have exited.
    @discardableResult
    static func endProcess(_ process: Process, force: Bool = false,
                           cooperative: TimeInterval = 2.0,
                           afterSignal: TimeInterval = 0.5) -> Bool {
        if !force, waitForExit(process, within: cooperative) { return true }

        // `terminate()` rather than a raw `kill`, so Foundation's own record of
        // whether this is still its child is what decides — a pid it has
        // already reaped could have been recycled onto an unrelated process.
        guard process.isRunning else { return true }
        process.terminate()
        if waitForExit(process, within: afterSignal) { return true }

        // SIGTERM can be trapped; SIGKILL cannot. Same guard, same reason.
        guard process.isRunning else { return true }
        kill(process.processIdentifier, SIGKILL)
        return waitForExit(process, within: afterSignal)
    }

    private static func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            usleep(5_000)
        }
        return !process.isRunning
    }

    func run(arguments: [String], files: [String]) throws -> ExiftoolRun {
        if Self.requiresOneShot(arguments: arguments, files: files) {
            return try runOneShot(arguments: arguments, files: files)
        }
        return try runStayOpen(arguments: arguments, files: files)
    }

    func shutdown() {
        session?.shutdown()
        session = nil
    }

    /// Terminates the session without waiting for a cooperative exit.
    func shutdownForcefully() {
        session?.shutdown(force: true)
        session = nil
    }

    // MARK: - One-shot

    private func runOneShot(arguments: [String], files: [String]) throws -> ExiftoolRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // `-config` has to come first; `--` ends option parsing, so a file
        // named "-foo.jpg" is a filename.
        process.arguments = leadingArguments + arguments + ["--"] + files

        let out = Pipe(), err = Pipe()
        // A prompting exiftool must fail, not hang waiting on a tty.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            throw ExiftoolRunnerError.launchFailed(String(describing: error))
        }

        // Both pipes are drained together: reading one to EOF first deadlocks
        // as soon as the other fills its 64 KB buffer.
        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        let drained: PipeDrain.Result
        do {
            drained = try PipeDrain.readToEnd(
                first: out.fileHandleForReading.fileDescriptor,
                second: err.fileHandleForReading.fileDescriptor,
                deadline: deadline)
        } catch {
            // A timed-out one-shot must not be left running: it still holds the
            // file open and may still be part-way through rewriting it. Bounded
            // for the same reason as `endProcess`'s doc comment gives.
            Self.endProcess(process, force: true)
            throw error
        }
        // Bounded, for the reason `endProcess` documents: both pipes are at EOF
        // by now, so the child has finished, but Foundation has been observed
        // to miss the termination anyway.
        let exited = Self.endProcess(process)

        return ExiftoolRun(stdout: String(decoding: drained.first, as: UTF8.self),
                           stderr: String(decoding: drained.second, as: UTF8.self),
                           // An exit status can only be read from a process
                           // known to have exited; anything else is reported as
                           // a failure rather than guessed at.
                           ok: exited && process.terminationStatus == 0,
                           route: .oneShot)
    }

    // MARK: - stay_open

    private func runStayOpen(arguments: [String], files: [String]) throws -> ExiftoolRun {
        let live: StayOpenSession
        if let session, session.isRunning {
            live = session
        } else {
            session?.shutdown()
            live = try StayOpenSession(executable: executable,
                                       leadingArguments: leadingArguments)
            session = live
        }

        // The command id carries the per-runner nonce, so the ready sentinel a
        // caption would have to spell in order to truncate a read-back is not
        // knowable to whoever wrote that caption.
        let commandID = "\(sentinelNonce)\(nextCommandNumber)"
        nextCommandNumber += 1
        do {
            let (stdout, stderr) = try live.execute(arguments: arguments + files,
                                                    commandID: commandID)
            // `-stay_open` reports no exit status per command, so "did it work"
            // has to be read off the output. This is only a first filter —
            // every write is judged by re-reading the tags, not by this string.
            let failed = stderr.contains("Error:")
                || stdout.contains("files weren't updated due to errors")
            return ExiftoolRun(stdout: stdout, stderr: stderr, ok: !failed, route: .stayOpen)
        } catch {
            // A wedged or dead session must not poison every later command, and
            // a session that timed out is by definition not going to answer a
            // polite `-stay_open False`.
            live.shutdown(force: true)
            session = nil
            throw error
        }
    }

    /// One `exiftool -stay_open True -@ -` process and the two pipes it answers on.
    private final class StayOpenSession {
        private let process = Process()
        private let stdin: FileHandle
        private let stdoutFD: Int32
        private let stderrFD: Int32
        private var isShutDown = false

        var isRunning: Bool { !isShutDown && process.isRunning }

        init(executable: String, leadingArguments: [String]) throws {
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            // `-config` is only honoured as the first option, so it belongs on
            // the launch line rather than in the per-command argfile.
            process.arguments = leadingArguments + ["-stay_open", "True", "-@", "-"]
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch {
                throw ExiftoolRunnerError.launchFailed(String(describing: error))
            }
            stdin = inPipe.fileHandleForWriting
            stdoutFD = outPipe.fileHandleForReading.fileDescriptor
            stderrFD = errPipe.fileHandleForReading.fileDescriptor
        }

        deinit { shutdown() }

        func execute(arguments: [String], commandID: String) throws -> (String, String) {
            let readySentinel = "{ready\(commandID)}"
            let errorSentinel = "{readyerr\(commandID)}"

            var script = ""
            for argument in arguments { script += argument + "\n" }
            // `-echo4` prints to stderr after the command is processed, which
            // gives stderr a terminator of its own. Without it there is no way
            // to know a command produced no diagnostics versus produced them
            // slowly, and the choice is between losing errors and blocking.
            script += "-echo4\n\(errorSentinel)\n-execute\(commandID)\n"

            guard let data = script.data(using: .utf8) else {
                throw ExiftoolRunnerError.launchFailed("argument list is not UTF-8")
            }
            do { try stdin.write(contentsOf: data) } catch {
                throw ExiftoolRunnerError.processDied("writing arguments: \(error)")
            }

            let deadline = Date().addingTimeInterval(ExiftoolRunner.commandTimeout)
            let drained = try PipeDrain.readUntil(
                first: stdoutFD, firstSentinel: readySentinel,
                second: stderrFD, secondSentinel: errorSentinel,
                deadline: deadline)
            return (String(decoding: drained.first, as: UTF8.self),
                    String(decoding: drained.second, as: UTF8.self))
        }

        /// - Parameter force: skip the polite `-stay_open False` and signal
        ///   straight away. Used when the session is being torn down *because*
        ///   it stopped answering.
        func shutdown(force: Bool = false) {
            guard !isShutDown else { return }
            isShutDown = true
            guard process.isRunning else {
                try? stdin.close()
                return
            }
            if !force {
                try? stdin.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
            }
            // EOF on stdin makes exiftool exit whether or not it read the
            // command, so this is the real teardown signal.
            try? stdin.close()
            ExiftoolRunner.endProcess(process, force: force)
        }
    }
}

/// Reads two file descriptors at once.
///
/// Single `poll(2)` over both, rather than a reader thread per pipe: whichever
/// descriptor has data is drained immediately, so neither can fill its 64 KB
/// buffer and block exiftool while this side waits on the other one. That
/// deadlock is the classic subprocess bug and it only shows up under load.
enum PipeDrain {
    struct Result { var first: Data; var second: Data }

    static func readToEnd(first: Int32, second: Int32, deadline: Date) throws -> Result {
        try drain(first: first, firstSentinel: nil,
                  second: second, secondSentinel: nil, deadline: deadline)
    }

    static func readUntil(first: Int32, firstSentinel: String,
                          second: Int32, secondSentinel: String,
                          deadline: Date) throws -> Result {
        try drain(first: first, firstSentinel: firstSentinel,
                  second: second, secondSentinel: secondSentinel, deadline: deadline)
    }

    private static func drain(first: Int32, firstSentinel: String?,
                              second: Int32, secondSentinel: String?,
                              deadline: Date) throws -> Result {
        var buffers = [Data(), Data()]
        let fds = [first, second]
        let sentinels = [firstSentinel.map { Data($0.utf8) },
                         secondSentinel.map { Data($0.utf8) }]
        var finished = [false, false]

        while !(finished[0] && finished[1]) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw ExiftoolRunnerError.timedOut(ExiftoolRunner.commandTimeout)
            }

            var poller = (0..<2).map { index in
                pollfd(fd: fds[index],
                       events: finished[index] ? 0 : Int16(POLLIN),
                       revents: 0)
            }
            // Capped so the deadline is still checked on a descriptor that has
            // simply gone quiet.
            let waitMilliseconds = Int32(min(remaining * 1000, 500).rounded(.up))
            let ready = poll(&poller, 2, waitMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ExiftoolRunnerError.processDied("poll failed: \(errno)")
            }
            if ready == 0 { continue }

            for index in 0..<2 where !finished[index] && poller[index].revents != 0 {
                // nil means "would block" — nothing to do but poll again.
                guard let chunk = try readChunk(fds[index]) else { continue }
                if chunk.isEmpty {
                    // EOF. Expected when draining a one-shot to the end; a
                    // broken promise when a sentinel was still owed.
                    if sentinels[index] != nil {
                        throw ExiftoolRunnerError.processDied("closed its output")
                    }
                    finished[index] = true
                    continue
                }
                buffers[index].append(chunk)
                if let sentinel = sentinels[index],
                   let start = anchoredSentinel(in: buffers[index], sentinel: sentinel) {
                    buffers[index].removeSubrange(start..<buffers[index].endIndex)
                    finished[index] = true
                }
            }
        }
        return Result(first: buffers[0], second: buffers[1])
    }

    /// The index at which a sentinel occupying a whole line begins, or nil.
    ///
    /// **Anchored, not "contains".** exiftool prints the ready sentinel on a
    /// line of its own, but the stream it prints it into also carries tag
    /// values — and a caption reading `{ready1}` would otherwise end the read
    /// mid-JSON, truncating the object and leaving the rest of it in the pipe
    /// to desynchronise the *next* command on the session. Requiring a newline
    /// on both sides (or the start of the stream on the left) means a value can
    /// only impersonate the sentinel by containing a newline — and a value
    /// containing a newline never reaches this protocol, because
    /// `requiresOneShot` routes it away.
    static func anchoredSentinel(in buffer: Data, sentinel: Data) -> Data.Index? {
        let newline = UInt8(ascii: "\n")
        var searchFrom = buffer.startIndex
        while searchFrom < buffer.endIndex,
              let found = buffer[searchFrom...].range(of: sentinel) {
            let precededByNewline = found.lowerBound == buffer.startIndex
                || buffer[buffer.index(before: found.lowerBound)] == newline
            let followedByNewline = found.upperBound < buffer.endIndex
                && buffer[found.upperBound] == newline
            if precededByNewline && followedByNewline { return found.lowerBound }
            // A partial match at the very end of the buffer may simply be
            // missing its trailing newline yet; leaving it unmatched lets the
            // next read complete it.
            searchFrom = found.lowerBound < buffer.endIndex
                ? buffer.index(after: found.lowerBound) : buffer.endIndex
        }
        return nil
    }

    /// Data on success, empty on EOF, nil when the descriptor would block.
    /// EOF and would-block have to be distinguishable: one ends the read, the
    /// other must not.
    private static func readChunk(_ fd: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw ExiftoolRunnerError.processDied("read failed: \(errno)")
        }
    }
}
