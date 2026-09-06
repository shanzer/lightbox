import SwiftUI
import LightboxCore

/// What the index knows about the selected files.
///
/// **Read-only in phase 1.** Editing arrives with `MetadataWriter` in phase 2,
/// and an editable field built now would be built twice: a writable inspector
/// needs undo, per-field dirty state, and a write-back path that reconciles
/// with the index, none of which exist yet.
///
/// With more than one row selected every field shows the value they agree on,
/// or `(multiple values)` where they do not — the same rule the Finder's
/// multiple-item Get Info uses, and the one an editable version will need.
struct InspectorView: View {
    let records: [FileRecord]

    /// Absent, agreed, or disagreed — three states, not two.
    ///
    /// Collapsing "every selected file agrees it has no camera" into the same
    /// nil that means "these files disagree" would put `(multiple values)`
    /// next to Camera for a folder of screenshots, none of which has a camera
    /// and all of which agree about it. `—` and `(multiple values)` are
    /// different claims about the data and the inspector has to be able to
    /// make both.
    private enum SharedValue {
        case value(String)
        case absent
        case mixed

        func map(_ transform: (String) -> String) -> SharedValue {
            switch self {
            case .value(let text): .value(transform(text))
            case .absent: .absent
            case .mixed: .mixed
            }
        }
    }

    var body: some View {
        Form {
            if records.isEmpty {
                Text("No selection").foregroundStyle(.secondary)
            } else {
                Section(records.count == 1
                        ? records[0].name
                        : "\(records.count) images selected") {
                    row("Dimensions", shared { record in
                        guard let width = record.width, let height = record.height else {
                            return nil
                        }
                        return "\(width) × \(height)"
                    })
                    row("Size", shared {
                        ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)
                    })
                    row("Captured", shared { record in
                        record.captureDate.map { Self.dateFormatter.string(from: $0) }
                    })
                    row("Time zone", shared(\.captureOffset))
                    row("Camera", shared { record in
                        [record.cameraMake, record.cameraModel]
                            .compactMap { $0 }
                            .joined(separator: " ")
                    })
                    row("Modified", shared {
                        Self.dateFormatter.string(from: $0.modifiedDate)
                    })
                }

                if records.count == 1 {
                    Section("Location") {
                        row("Path", .value(records[0].path))
                    }
                }

                Section("Hashes") {
                    row("Content", shared(\.contentHash).map(Self.abbreviated))
                    row("Image data", shared(\.imageHash).map(Self.abbreviated))
                    row("Rule", shared(\.imageHashKind))
                    row("Perceptual", shared(\.phash).map(Self.abbreviated))
                    if records.contains(where: { $0.hashedAt == nil }) {
                        Text(records.count == 1
                             ? "Not yet hashed."
                             : "Some of these are not yet hashed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A full content hash is 64 hex characters and would force the inspector
    /// as wide as a value nobody reads in full. The prefix is enough to
    /// compare two rows by eye, and the text stays selectable for the rest.
    private static func abbreviated(_ value: String) -> String {
        value.count > 16 ? String(value.prefix(16)) + "…" : value
    }

    @ViewBuilder
    private func row(_ label: String, _ value: SharedValue) -> some View {
        LabeledContent(label) {
            switch value {
            case .value(let text):
                Text(text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            case .absent:
                Text("—").foregroundStyle(.secondary)
            case .mixed:
                Text("(multiple values)").foregroundStyle(.secondary)
            }
        }
    }

    /// The value every selected record agrees on.
    ///
    /// Empty and absent are folded together on purpose: a record with
    /// `cameraMake == ""` and one with `cameraMake == nil` do not disagree
    /// about anything a user would recognise, and reporting them as mixed
    /// would be a lie about the data.
    private func shared(_ extract: (FileRecord) -> String?) -> SharedValue {
        var agreed: String?
        for record in records {
            let value = extract(record) ?? ""
            if let agreed {
                guard agreed == value else { return .mixed }
            } else {
                agreed = value
            }
        }
        guard let agreed, !agreed.isEmpty else { return .absent }
        return .value(agreed)
    }

    private func shared(_ keyPath: KeyPath<FileRecord, String?>) -> SharedValue {
        shared { $0[keyPath: keyPath] }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
