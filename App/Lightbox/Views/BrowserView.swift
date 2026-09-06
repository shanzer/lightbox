import SwiftUI
import LightboxCore

struct BrowserView: View {
    @State private var model: BrowserModel?
    @State private var loadError: String?

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
    }

    private func start() {
        do {
            model = try BrowserModel()
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
