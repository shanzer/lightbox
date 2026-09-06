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

                progressIndicator

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
