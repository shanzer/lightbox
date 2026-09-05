import Foundation

public struct WalkEntry: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let mtime: Date
    /// Volume identifier. An inode is unique only within its volume, so an
    /// index spanning an external drive and the internal disk needs both
    /// halves to identify a file.
    public let device: Int64
    public let inode: Int64
    public let mediaType: MediaType
}

public enum SkipReason: String, Sendable, Hashable {
    /// A directory that could not be identified or enumerated.
    case unreadable
    case symlinkLoop
    /// A directory entry whose `stat` failed for a reason other than the file
    /// having been deleted. It is emitted so a caller can tell "this file is
    /// gone" from "I could not look at this file": only the former is evidence
    /// that an index row should be removed.
    case unstatable
}

public enum WalkEvent: Sendable {
    case entry(WalkEntry)
    case skipped(url: URL, reason: SkipReason)
}

public struct WalkOptions: Sendable {
    public var includeSubdirectories: Bool
    public var followSymlinks: Bool

    public init(includeSubdirectories: Bool = true, followSymlinks: Bool = false) {
        self.includeSubdirectories = includeSubdirectories
        self.followSymlinks = followSymlinks
    }
}

/// Enumerates a directory tree, emitting one event per supported image found
/// and one per directory that could not be read.
///
/// Iterative rather than recursive: a deep tree must not risk the stack, and an
/// explicit stack makes the symlink-loop guard trivial to reason about.
public struct Walker: Sendable {
    /// Directories whose contents are implementation detail of an application
    /// or library, never a user's photos. Descending into a `.photoslibrary`
    /// yields tens of thousands of derivative files and no useful originals.
    private static let opaqueBundleExtensions: Set<String> = [
        "photoslibrary", "aplibrary", "migratedaplibrary", "lrdata", "lrcat",
        "app", "bundle", "framework", "photolibrary", "pkg",
    ]

    public init() {}

    public func scan(root: URL, options: WalkOptions, onEvent: (WalkEvent) -> Void) {
        var stack: [URL] = [root]
        var visited = Set<DirectoryIdentity>()

        while let dir = stack.popLast() {
            // Synchronous, but callers run it inside a Task; without this a
            // 50k-file tree on a slow external drive cannot be interrupted.
            if Task.isCancelled { return }

            guard let identity = DirectoryIdentity(path: dir.path, followSymlink: true) else {
                onEvent(.skipped(url: dir, reason: .unreadable))
                continue
            }
            guard visited.insert(identity).inserted else {
                onEvent(.skipped(url: dir, reason: .symlinkLoop))
                continue
            }

            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            } catch {
                onEvent(.skipped(url: dir, reason: .unreadable))
                continue
            }

            for name in names {
                if Self.isJunk(name) { continue }
                let child = dir.appendingPathComponent(name)

                var st = stat()
                if lstat(child.path, &st) != 0 {
                    // ENOENT is the file being deleted between the listing and
                    // this stat: genuinely gone, and an index row for it should
                    // go too, so it is dropped silently. Any other errno — EIO
                    // on a flaky external volume, EACCES from a permission
                    // change mid-walk — means the file may well still be there
                    // and we merely could not look at it. Dropping that one
                    // silently would let a caller read it as a deletion.
                    if errno != ENOENT { onEvent(.skipped(url: child, reason: .unstatable)) }
                    continue
                }

                if st.st_mode & S_IFMT == S_IFLNK {
                    guard options.followSymlinks else { continue }
                    var resolved = stat()
                    if stat(child.path, &resolved) != 0 {
                        // A dangling symlink resolves to ENOENT and is as dead
                        // as a deleted file; anything else is a failure to look.
                        if errno != ENOENT { onEvent(.skipped(url: child, reason: .unstatable)) }
                        continue
                    }
                    st = resolved
                }

                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    guard options.includeSubdirectories else { continue }
                    let ext = child.pathExtension.lowercased()
                    guard !Self.opaqueBundleExtensions.contains(ext) else { continue }
                    stack.append(child)
                case S_IFREG:
                    guard let mediaType = MediaType.forExtension(child.pathExtension) else { continue }
                    onEvent(.entry(WalkEntry(
                        url: child,
                        size: Int64(st.st_size),
                        mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                    + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000),
                        device: Int64(st.st_dev),
                        inode: Int64(bitPattern: UInt64(st.st_ino)),
                        mediaType: mediaType)))
                default:
                    continue
                }
            }
        }
    }

    /// Names that are never user content: Finder metadata, AppleDouble
    /// resource forks, and anything hidden.
    static func isJunk(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("._") || name == "Icon\r"
    }
}

/// A directory's identity on disk, so a symlink cannot make the walker revisit
/// a tree it has already descended.
private struct DirectoryIdentity: Hashable {
    let device: Int64
    let inode: Int64

    init?(path: String, followSymlink: Bool) {
        var st = stat()
        let ok = followSymlink ? stat(path, &st) == 0 : lstat(path, &st) == 0
        guard ok, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        device = Int64(st.st_dev)
        inode = Int64(bitPattern: UInt64(st.st_ino))
    }
}
