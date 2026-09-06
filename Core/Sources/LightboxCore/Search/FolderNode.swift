import Foundation

/// One directory in the sidebar tree.
public struct FolderNode: Sendable, Hashable, Identifiable {
    public let url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL) { self.url = url }

    /// Immediate subdirectories, sorted for display.
    ///
    /// Shares `Walker`'s notion of what is not user content, so the sidebar and
    /// the grid never disagree about whether a folder exists. In particular the
    /// `lstat` is deliberate rather than a `stat`: `Walker` does not follow
    /// symlinks by default, so a link pointing at a directory is not something
    /// the grid would ever populate and must not appear here either.
    ///
    /// Returns an empty array for anything that cannot be enumerated — missing,
    /// unreadable, or not a directory at all. The sidebar has no way to report
    /// an error per row and no action to offer if it could; the grid's own
    /// `rootUnreadable` is where an unreachable folder is surfaced.
    public static func children(of url: URL) -> [FolderNode] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return names
            .filter { !Walker.isJunk($0) }
            .map { url.appendingPathComponent($0, isDirectory: true) }
            .filter { child in
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
                    return false
                }
                return !Walker.opaqueBundleExtensions.contains(child.pathExtension.lowercased())
            }
            .map(FolderNode.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
