import SwiftUI

extension View {
    /// Publishes one text field's focus into the model.
    ///
    /// A named modifier in a file of its own rather than three copies of the
    /// same `onChange`, because it is a **cross-file contract**: every text
    /// field in the app must call it, and a field that forgets leaves ⌘Z
    /// reversing the last batch while the user types in it. Buried at the
    /// bottom of whichever view happened to need it first, that obligation is
    /// invisible to the next field's author. `BrowserModel.TextField` is the
    /// checklist.
    ///
    /// `initial: true` so a field that is focused as it appears reports itself
    /// rather than waiting for the first change.
    ///
    /// **`onDisappear` clears it, and that is not belt-and-braces.** A focused
    /// field can be torn down without ever reporting a blur — collapsing the
    /// sidebar (its toolbar button, or View ▸ Hide Sidebar) takes
    /// `FilterPanelView` with it while a size field has focus. Without this the
    /// field stays in the set, `isEditingText` stays true, and ⌘Z routes to a
    /// text field that is no longer on screen: the forward finds nothing, so
    /// the window silently stops undoing until that same field is focused and
    /// blurred again.
    func reportingTextFocus(_ field: BrowserModel.TextField,
                            isFocused: Bool,
                            to model: BrowserModel) -> some View {
        onChange(of: isFocused, initial: true) { _, focused in
            model.setEditing(field, focused)
        }
        .onDisappear { model.setEditing(field, false) }
    }
}
