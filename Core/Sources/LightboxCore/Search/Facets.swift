/// How a result set breaks down, for the filter panel.
///
/// A value rather than a live query so the panel can render counts without
/// knowing anything about SQL, and so a test can state the whole answer in one
/// `#expect`. Empty dictionaries are the honest answer for a result set with no
/// rows: `byExtension == [:]` means "nothing matched", which is what the panel
/// should say, and is distinct from never having run the query at all.
public struct Facets: Sendable, Hashable {
    /// Counts by lowercase file extension, excluding rows with none.
    public let byExtension: [String: Int]
    /// Counts by camera make, excluding rows with none.
    public let byCamera: [String: Int]
    /// Rows matching the query — including the ones with no extension or no
    /// camera, so this is *not* the sum of either dictionary.
    public let total: Int

    public static let empty = Facets(byExtension: [:], byCamera: [:], total: 0)

    public init(byExtension: [String: Int], byCamera: [String: Int], total: Int) {
        self.byExtension = byExtension
        self.byCamera = byCamera
        self.total = total
    }
}
