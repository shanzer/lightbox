import AppKit
import UniformTypeIdentifiers

/// The file picker behind the inspector's *Choose…* (#51).
///
/// A free function over AppKit rather than a SwiftUI `fileImporter`, for the
/// same reason `DestinationChooser` is one: the importer has no accessory view
/// and no way to start the user somewhere useful, and both matter here. An
/// exiftool that none of #41's four rungs can see is by definition somewhere
/// unusual, so the panel opens showing hidden files and accepts a path typed
/// straight in — ⇧⌘G works in any open panel, and for a `/usr/local`-style
/// prefix it is faster than navigating.
@MainActor
enum ExiftoolChooser {
    /// Runs the panel modally and returns the chosen file's path, or nil if
    /// the user cancelled.
    ///
    /// **Nothing is validated here.** The caller runs
    /// `ExiftoolLocator.validate` — through the writer seam, off the main
    /// thread, because it forks — and refuses the choice if it is not a usable
    /// exiftool. Splitting it that way keeps the fork out of the modal loop.
    static func chooseExecutable() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use This exiftool"
        panel.message = "Choose the exiftool program Lightbox should use."

        // A hint, not a filter. exiftool ships as a Perl script with no
        // extension, so `allowedContentTypes` would hide the very file being
        // looked for on most installs; `unixExecutable` alone excludes a
        // perfectly good `#!/usr/bin/perl` script.
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
