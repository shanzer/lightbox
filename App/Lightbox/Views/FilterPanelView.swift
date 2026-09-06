import SwiftUI
import LightboxCore

/// The faceted filter panel, under the folder tree.
///
/// Every count comes from `BrowserModel.facets`, which describes the whole
/// result set rather than the page on screen, so a row saying `.png 3,412`
/// means ticking it would find 3,412 files.
struct FilterPanelView: View {
    @Bindable var model: BrowserModel

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
                    .disabled(model.root == nil)
                Text("Reads every file. Needed for duplicate detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
