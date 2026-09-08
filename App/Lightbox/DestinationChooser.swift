import AppKit

/// The folder picker behind Move To… and Copy To….
///
/// `NSOpenPanel` in choose-directory mode, with the companion-files checkbox as
/// its accessory view — spec §8's toggle, put where the decision is actually
/// being made rather than buried in a preferences window the user would have to
/// know exists.
///
/// A free function over AppKit rather than a SwiftUI `fileImporter`: the
/// importer offers no accessory view, and the toggle has to travel with the
/// panel it modifies.
@MainActor
enum DestinationChooser {
    struct Choice {
        let destination: URL
        let includeCompanions: Bool
    }

    /// Runs the panel modally and returns what the user chose, or nil if they
    /// cancelled. The checkbox's state comes back alongside the folder, so the
    /// caller writes the preference in one place.
    static func chooseDirectory(prompt: String, message: String,
                                includeCompanions: Bool) -> Choice? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message

        let checkbox = NSButton(
            checkboxWithTitle: "Include companion files (RAW+JPEG pairs, .xmp, .aae, .thm)",
            target: nil, action: nil)
        checkbox.state = includeCompanions ? .on : .off
        checkbox.toolTip = "Sidecars and RAW/JPEG partners travel with the image. "
            + "Turning this off leaves them behind."
        checkbox.sizeToFit()

        // A container with room around the control: an accessory view sized
        // exactly to its checkbox sits flush against the panel's buttons.
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: checkbox.frame.width + 40, height: 32))
        checkbox.frame.origin = CGPoint(x: 20, y: 7)
        container.addSubview(checkbox)
        panel.accessoryView = container
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Choice(destination: url, includeCompanions: checkbox.state == .on)
    }
}
