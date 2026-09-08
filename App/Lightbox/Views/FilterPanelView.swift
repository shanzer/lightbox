import SwiftUI
import LightboxCore

/// The faceted filter panel, under the folder tree.
///
/// Every count comes from `BrowserModel.facets`, which describes the whole
/// result set rather than the page on screen, so a row saying `.png 3,412`
/// means ticking it would find 3,412 files.
struct FilterPanelView: View {
    @Bindable var model: BrowserModel

    /// Reported into the model so ⌘Z reaches these fields' own undo while they
    /// are being typed in — see `BrowserModel.isEditingText`.
    @FocusState private var widthFocused: Bool
    @FocusState private var heightFocused: Bool

    /// A struct rather than the tuple the brief used: Swift has no key paths
    /// to tuple elements, so `ForEach(_:id: \.0)` does not compile.
    private struct WidthPreset: Identifiable, Hashable {
        let id: String
        let value: Double?
    }

    private static let widthPresets: [WidthPreset] = [
        WidthPreset(id: "Any width", value: nil),
        WidthPreset(id: "≥ 1000 px", value: 1000),
        WidthPreset(id: "≥ 1920 px", value: 1920),
        WidthPreset(id: "≥ 4000 px", value: 4000),
    ]

    var body: some View {
        Form {
            Section("File type") {
                if model.facets.byExtension.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                } else {
                    ForEach(model.facets.byExtension.sorted(by: { $0.key < $1.key }),
                            id: \.key) { ext, matches in
                        Toggle(isOn: binding(for: ext)) {
                            LabeledContent(".\(ext)") { count(matches) }
                        }
                    }
                }
            }

            Section("Dimensions") {
                Picker("Width", selection: $model.minimumWidth) {
                    ForEach(Self.widthPresets) { preset in
                        Text(preset.id).tag(preset.value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                // The presets answer "big enough?"; this answers "exactly this
                // size?", which the width menu cannot express at all and which
                // is how you find every 200×200 icon in a library.
                LabeledContent("Exact size") {
                    HStack(spacing: 6) {
                        TextField("Width", text: exactBinding(\.exactWidth))
                            .frame(width: 64)
                            .focused($widthFocused)
                            .reportingTextFocus(.exactWidth, isFocused: widthFocused,
                                                to: model)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: exactBinding(\.exactHeight))
                            .frame(width: 64)
                            .focused($heightFocused)
                            .reportingTextFocus(.exactHeight, isFocused: heightFocused,
                                                to: model)
                    }
                    .textFieldStyle(.roundedBorder)
                }

                // Only while exactly one half is filled. Without it a
                // half-entered pair looks like a filter that silently did
                // nothing, which is indistinguishable from a broken one.
                if (model.exactWidth == nil) != (model.exactHeight == nil) {
                    Text("Enter both a width and a height to filter by exact size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Camera") {
                if model.facets.byCamera.isEmpty {
                    // Read-only in phase 1: there is no camera filter control
                    // yet, so this section is a breakdown, not a filter.
                    Text("No camera information").foregroundStyle(.secondary)
                } else {
                    ForEach(model.facets.byCamera.sorted(by: { $0.key < $1.key }),
                            id: \.key) { make, matches in
                        LabeledContent(make) { count(matches) }
                    }
                }
            }

            Section {
                LabeledContent("Matching files") { count(model.facets.total) }
                Button("Clear Filters") { model.clearFilters() }
                    .disabled(!model.hasActiveFilters)
            }

            Section("Content hashes") {
                Button("Compute Hashes for This Folder") { model.startHashingPass() }
                    // Disabled while paused rather than silently doing nothing:
                    // a paused coordinator would return a fresh pass straight
                    // back at its first batch boundary, so the only honest way
                    // forward from a pause is the resume button below.
                    .disabled(model.root == nil || model.isHashingPaused)

                Button(model.isHashingPaused ? "Resume Hashing" : "Pause Hashing") {
                    Task {
                        if model.isHashingPaused {
                            await model.resumeHashing()
                        } else {
                            await model.pauseHashing()
                        }
                    }
                }
                .disabled(!model.isHashingActive)

                Text("Reads every file. Needed for duplicate detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isHashingPaused {
                    Text("Paused. Nothing already hashed is lost — resuming picks up the rest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for ext: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedExtensions.contains(ext) },
            set: { isOn in
                if isOn {
                    model.selectedExtensions.insert(ext)
                } else {
                    model.selectedExtensions.remove(ext)
                }
            })
    }

    /// Bridges one half of the exact-size filter to a text field.
    ///
    /// A `String` binding rather than `TextField(value:format:)`: the model
    /// half is `Int?` because "no value" is a filter state, and the numeric
    /// `TextField` initialisers bind a non-optional. Non-digits are dropped
    /// rather than stored, and anything that is not a positive size — an empty
    /// field, a lone `0` — clears the half, which is what turns the filter off.
    private func exactBinding(
        _ keyPath: ReferenceWritableKeyPath<BrowserModel, Int?>
    ) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath].map(String.init) ?? "" },
            set: { text in
                let value = Int(text.filter(\.isNumber))
                model[keyPath: keyPath] = (value ?? 0) > 0 ? value : nil
            })
    }

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
