import Foundation

/// Which files travel with an image.
///
/// Spec §8: same-basename `.xmp`, `.aae` and `.thm` sidecars, plus the other
/// half of a RAW+JPEG pair. Not doing this silently orphans edits — an `.xmp`
/// left behind is a Lightroom crop that no longer applies to anything, and a
/// JPEG left behind when its RAW moves is the pair broken.
///
/// Matching is on the basename, **case-insensitively**, and the direction runs
/// both ways: selecting `IMG_0001.CR2` takes `IMG_0001.JPG`, and selecting
/// `IMG_0001.JPG` takes `IMG_0001.CR2`. Case-insensitive because the volumes
/// this app is built for are APFS and HFS+ in their default, case-insensitive
/// configuration, where `IMG_0001.xmp` and `img_0001.XMP` are the same name;
/// on a case-sensitive volume the rule is deliberately the looser one, because
/// over-collecting a sidecar keeps a pair together and under-collecting it
/// breaks one.
enum CompanionFiles {
    /// Sidecar extensions, lowercased. `.xmp` is Adobe's edit sidecar, `.aae`
    /// is Photos' adjustment record, `.thm` the camera-written thumbnail.
    static let sidecarExtensions: Set<String> = ["xmp", "aae", "thm"]

    /// The companions of `url` among `siblingNames` (the names in `url`'s own
    /// directory), excluding anything whose path is in `excluding`.
    ///
    /// **Names, not URLs, and the result is built by appending each name to
    /// `url`'s own directory.** `FileManager.contentsOfDirectory(at:)` hands
    /// back URLs with symlinks resolved — a temporary directory under `/var`
    /// comes back under `/private/var` — and `files.path` holds whatever the
    /// walker was given. Taking the URLs the enumerator returns would produce
    /// companion paths that no index row matches, so the companion's row would
    /// silently stay behind while its file moved: a `.xmp` in the new folder
    /// and a row pointing at the old one.
    ///
    /// `excluding` is how a selection that already contains both halves of a
    /// RAW+JPEG pair avoids handling either of them twice: the pair is one
    /// item with one companion, not two items that each claim the other.
    static func companions(of url: URL, siblingNames: [String],
                           excluding: Set<String>) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let sourceKind = MediaType.forExtension(url.pathExtension)?.kind
        return siblingNames.sorted()
            .map { directory.appendingPathComponent($0) }
            .filter { candidate in
                guard candidate.path != url.path,
                      !excluding.contains(candidate.path) else { return false }
                guard candidate.deletingPathExtension()
                        .lastPathComponent.lowercased() == stem else { return false }
                let ext = candidate.pathExtension.lowercased()
                if sidecarExtensions.contains(ext) { return true }
                guard let sourceKind,
                      let candidateKind = MediaType.forExtension(ext)?.kind else { return false }
                return isPair(sourceKind, candidateKind)
            }
    }

    private static func isPair(_ a: MediaKind, _ b: MediaKind) -> Bool {
        (a == .raw && b == .jpeg) || (a == .jpeg && b == .raw)
    }
}
