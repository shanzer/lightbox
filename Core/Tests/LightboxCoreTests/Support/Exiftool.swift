import Foundation

/// Runs exiftool if it is installed; returns false when it is not, so the
/// suite stays green on a machine without it.
@discardableResult
func exiftool(_ args: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["exiftool"] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

var exiftoolAvailable: Bool { exiftool(["-ver"]) }
