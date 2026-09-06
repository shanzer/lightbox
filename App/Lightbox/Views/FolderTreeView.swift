import SwiftUI
import LightboxCore

struct FolderTreeView: View {
    let model: BrowserModel
    @State private var roots: [FolderNode] = []

    var body: some View {
        List {
            OutlineGroup(roots, id: \.id, children: \.loadedChildren) { node in
                Text(node.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.open(node.url) } }
            }
        }
        .task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
            // Only offer a root that exists; an empty sidebar is better than a
            // row that expands to nothing.
            roots = FileManager.default.fileExists(atPath: pictures.path)
                ? [FolderNode(url: pictures)]
                : [FolderNode(url: home)]
        }
    }
}

private extension FolderNode {
    /// `OutlineGroup` wants an optional array; nil means "no disclosure arrow".
    var loadedChildren: [FolderNode]? {
        let kids = FolderNode.children(of: url)
        return kids.isEmpty ? nil : kids
    }
}
