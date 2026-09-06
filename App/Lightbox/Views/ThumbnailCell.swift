import SwiftUI
import LightboxCore

struct ThumbnailCell: View {
    let record: FileRecord
    let side: CGFloat
    let isSelected: Bool
    let cache: ThumbnailCache

    /// Everything the cached image depends on.
    ///
    /// `.task(id:)` restarts on any change to this and on nothing else, which
    /// is what keeps a slider drag from launching a QuickLook render per point
    /// of travel: `pixels` is quantised, so most of the drag changes no key at
    /// all. `mtime` is in here because the cache keys on it — a file edited in
    /// place invalidates its own thumbnail — and the cell has to ask again to
    /// see that.
    private struct Request: Hashable {
        var id: Int64?
        var mtime: Double
        var pixels: Int
    }

    /// The pixel size asked of the cache for a cell `side` points wide.
    ///
    /// Quantised rather than exact for two reasons. The cache keys on the
    /// requested size, so an exact request would make every pixel of slider
    /// travel a distinct cache entry — a few hundred QuickLook renders and a
    /// few hundred files on disk for one drag. And a thumbnail scaled down by a
    /// factor under two is indistinguishable from one rendered at the exact
    /// size, so the cost buys nothing.
    ///
    /// Doubled first for a Retina display, then rounded *up* to the next step,
    /// so the image is never scaled up. `internal` so a test can pin the
    /// buckets: this is the one thing in the cell that is not a view.
    static let sizeStep = 256
    static let maximumPixels = 1024

    static func requestedPixels(for side: CGFloat) -> Int {
        let wanted = max(1, Int((side * 2).rounded(.up)))
        let stepped = ((wanted + sizeStep - 1) / sizeStep) * sizeStep
        return min(stepped, maximumPixels)
    }

    /// How many times a vanished cache file is re-requested before the cell
    /// gives up. Eviction can delete a thumbnail between the cache handing back
    /// its URL and this cell reading it, and that is ordinary operation, not a
    /// failure; one retry is enough for it to be regenerated, and a small cap
    /// keeps a genuinely undecodable PNG from spinning.
    private static let attempts = 3

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }

            Text(record.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.name)
        .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
        // Starts when the cell scrolls into view and is cancelled when it
        // scrolls out, so a cell the user has already passed stops waiting on
        // its image. Note that this cancels the *wait*, not the render: a
        // QuickLook generation is shared between every cell asking for the same
        // key, so one caller walking away must not take it down.
        .task(id: Request(id: record.id, mtime: record.mtime,
                          pixels: Self.requestedPixels(for: side))) {
            await load()
        }
    }

    private func load() async {
        // The cache keys on `url.path` verbatim: `/a/b.jpg` and `/a/./b.jpg`
        // are two keys for one file and cost two renders. The index stores
        // walked paths, which are already standard, but the precondition is the
        // caller's to meet and this is the caller.
        let url = URL(fileURLWithPath: record.path).standardizedFileURL
        let pixels = Self.requestedPixels(for: side)

        for _ in 0..<Self.attempts {
            guard !Task.isCancelled else { return }
            let thumbnail = try? await cache.thumbnail(
                for: url, mtime: record.mtime, size: pixels)
            // Checked on the far side of the await as well as before it: the
            // cell may have scrolled out of view while QuickLook was rendering,
            // and a cancelled cell must not paint a result — least of all the
            // failure glyph, if `try?` swallowed a cancellation.
            guard !Task.isCancelled else { return }
            guard let thumbnail else {
                failed = true
                return
            }
            if let loaded = NSImage(contentsOf: thumbnail) {
                image = loaded
                failed = false
                return
            }
            // Nothing was read back. Either the entry was evicted between the
            // cache returning its URL and this line — eviction is by write time
            // and takes no account of what is on screen, so a tile in the
            // viewport is as evictable as any other — or the PNG is unreadable.
            // Only the first is worth another go, and asking again regenerates
            // it because the cache checks the file's existence first.
            guard !FileManager.default.fileExists(atPath: thumbnail.path) else {
                failed = true
                return
            }
        }
        failed = true
    }
}
