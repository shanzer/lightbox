import SwiftUI

/// **The one text field the metadata UI is built from.**
///
/// Both the inspector's ten boxes and the batch time sheet's six go through
/// here, and that is the point rather than tidiness: `reportingTextFocus` is a
/// cross-file contract — a field that forgets it leaves ⌘Z reversing the last
/// file batch while the user types — and two builders means two places to
/// forget it, only one of which any test walks. With one, dropping the modifier
/// reddens `everyInspectorFieldReportsItsFocus`.
///
/// `clear` draws the erase control beside the box. It is present only for the
/// fields `MetadataField.isClearable` names, because blank means *unchanged*
/// everywhere in this editor and erasing therefore needs a gesture of its own.
struct MetadataTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let id: BrowserModel.TextField
    @FocusState.Binding var focused: BrowserModel.TextField?
    let model: BrowserModel
    var isEnabled: Bool = true
    var onSubmit: () -> Void = {}
    var clear: (() -> Void)?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: id)
                    .reportingTextFocus(id, isFocused: focused == id, to: model)
                    .disabled(!isEnabled)
                    .onSubmit(onSubmit)
                if let clear {
                    Button {
                        clear()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isEnabled)
                    .help("Erase \(label) on the selection")
                    .accessibilityLabel("Erase \(label)")
                }
            }
        }
    }
}
