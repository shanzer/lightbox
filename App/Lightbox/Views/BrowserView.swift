import SwiftUI
import LightboxCore

struct BrowserView: View {
    @State private var model: BrowserModel?
    @State private var loadError: String?

    /// The index this window is to open, or nil when this launch must not open
    /// one — see `LaunchEnvironment`. A stored property rather than a call in
    /// `start()`, so the branch that renders the inert scene and the branch
    /// that builds the model cannot disagree about which launch this is.
    ///
    /// Not private, and injected through the initialiser's default rather than
    /// hardcoded here, so a test can read back what the view resolved. That is
    /// the only way to catch the mutation that matters: pinning this to
    /// `IndexStore.defaultURL` leaves every test of `LaunchEnvironment` itself
    /// green while the test host opens the user's index again.
    let launchIndexURL: URL?

    init(launchIndexURL: URL? = LaunchEnvironment.launchIndexURL()) {
        self.launchIndexURL = launchIndexURL
    }

    var body: some View {
        Group {
            if let model {
                NavigationSplitView {
                    // The tree and the filters share one column: they are both
                    // "what am I looking at", and a third split would leave
                    // the grid — the point of the window — with the least
                    // room of the three.
                    VStack(spacing: 0) {
                        FolderTreeView(model: model)
                        Divider()
                        FilterPanelView(model: model)
                            .frame(maxHeight: 420)
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    HSplitView {
                        VStack(spacing: 0) {
                            PathBarView(model: model)
                            Divider()
                            PhotoGridView(records: model.records,
                                          order: model.order,
                                          cache: model.thumbnails,
                                          selection: Bindable(model).selection,
                                          thumbnailSide: model.thumbnailSide)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(minWidth: 320)

                        InspectorView(records: model.selectedRecords)
                            .frame(minWidth: 240, idealWidth: 300)
                    }
                    .overlay(alignment: .top) {
                        // Shown once, for the session the rebuild happened in.
                        // A silent rebuild would look exactly like the index —
                        // and therefore every folder in it — had lost its
                        // contents, rather than just its cache.
                        if model.didRebuildIndex {
                            Text("The index was damaged and has been rebuilt. "
                                + "Folders will be rescanned as you open them.")
                                .font(.callout)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
                }
            } else if launchIndexURL == nil {
                // The window an `xcodebuild test` run puts on screen. Inert on
                // purpose, and worded rather than blank: this scene is visible
                // for the length of the run, and "no index was opened" is the
                // one thing worth saying about it.
                ContentUnavailableView("No index opened",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Lightbox is hosting a test "
                                           + "bundle and will not open the index."))
            } else if let loadError {
                ContentUnavailableView("Could not open the index",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView().task { start() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshFolder)) { _ in
            guard let model else { return }
            Task { await model.refreshCurrentFolder() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAllPhotos)) { _ in
            model?.selectAll()
        }
        // What the file-operation commands act on. A focused value rather than
        // a notification, because a batch belongs to one window — see
        // `FocusedValues.browserModel`.
        .focusedSceneValue(\.browserModel, model)
        .sheet(item: sheet) { active in
            if let model {
                FileOperationSheetView(model: model, sheet: active)
            }
        }
    }

    /// The sheet binding. Written by hand rather than `Bindable(model)` because
    /// `model` is an optional `@State` here, and because setting it to nil has
    /// to go through the model's own dismissal — the batch and the sheet are
    /// not the same thing, and a sheet dismissed from the outside must not look
    /// like a cancelled batch.
    private var sheet: Binding<ActiveSheet?> {
        Binding(get: { model?.activeSheet },
                set: { if $0 == nil { model?.dismissSheet() } })
    }

    private func start() {
        // Unreachable under a test host — the view renders the inert scene
        // instead of the `ProgressView` that calls this — but the guard is
        // repeated rather than assumed, because `BrowserModel` opens, migrates
        // and WAL-switches whatever URL it is handed, and this is the only
        // caller that gets to choose one.
        guard let launchIndexURL else { return }
        do {
            model = try BrowserModel(at: launchIndexURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.open(url) }
    }
}
