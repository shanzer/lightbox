import SwiftUI
import LightboxCore

struct PathBarView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(model.root?.path ?? "No folder open")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(model.root == nil ? .secondary : .primary)

                Spacer(minLength: 12)

                // Bound straight to `searchText`; the debounce lives in the
                // model, so the field stays responsive per keystroke while
                // the index is queried once per pause.
                TextField("Search filenames", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .help("Matches file names. The last word is a prefix, so \"bea\" finds \"beach\".")

                Picker("Sort", selection: $model.sort.field) {
                    ForEach(SearchQuery.SortField.allCases, id: \.self) { field in
                        Text(Self.title(for: field)).tag(field)
                    }
                }
                .frame(width: 150)

                // Separate from the field, not two entries per field in one
                // menu: the direction is orthogonal to what is being sorted,
                // and doubling the menu makes both harder to scan.
                Button {
                    model.sort.ascending.toggle()
                } label: {
                    Image(systemName: model.sort.ascending
                          ? "arrow.up" : "arrow.down")
                }
                .help(model.sort.ascending ? "Ascending" : "Descending")

                progressIndicator

                // Resizes cells continuously. The thumbnails behind them are
                // requested at quantised sizes, so a drag across the whole
                // range costs a handful of renders, not one per point.
                Slider(value: $model.thumbnailSide, in: 64...320) { Text("Size") }
                    .labelsHidden()
                    .frame(width: 120)
                    .help("Thumbnail size")

                Toggle("Include Subfolders", isOn: $model.includeSubfolders)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }

            if let message = model.status.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// `SortField.rawValue` is a Swift identifier — `captureDate` — and the
    /// menu is read by a person, so the two are kept apart rather than
    /// showing camelCase in the UI.
    private static func title(for field: SearchQuery.SortField) -> String {
        switch field {
        case .name: "Name"
        case .captureDate: "Date Taken"
        case .modifiedDate: "Date Modified"
        case .size: "File Size"
        case .width: "Width"
        case .height: "Height"
        }
    }

    /// Driven by `phase`, never by `fraction`.
    ///
    /// `IndexProgress.completed` counts files actually re-read, so a rescan of
    /// an unchanged folder runs its whole reading phase at `fraction == 0` and
    /// finishes there. A bar bound to `fraction` would sit at zero and then
    /// vanish, which reads as "nothing happened" on the single most common
    /// case. So the phase decides whether anything is shown at all, and a
    /// determinate bar appears only once there is real work to measure.
    @ViewBuilder
    private var progressIndicator: some View {
        switch model.progress.phase {
        case .idle, .finished:
            EmptyView()

        case .walking:
            // Nothing is countable yet: the walk is still discovering the total.
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
            Text("Scanning…")
                .foregroundStyle(.secondary)

        case .reading, .hashing:
            if model.progress.completed > 0 {
                ProgressView(value: Double(model.progress.completed),
                             total: Double(max(model.progress.total, model.progress.completed)))
                    .frame(width: 120)
                Text("\(model.progress.completed)/\(model.progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                Text(model.progress.phase == .hashing ? "Hashing…" : "Reading…")
                    .foregroundStyle(.secondary)
            }

        case .paused:
            Text("Paused")
                .foregroundStyle(.secondary)
        }
    }
}
