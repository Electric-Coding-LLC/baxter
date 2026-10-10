import SwiftUI

struct RestoreBrowserTree: View {
    let roots: [RestoreBrowserNode]
    let forceExpanded: Bool
    let expandedPaths: Set<String>
    let loadingPaths: Set<String>
    @Binding var selection: String?
    let isDirectory: (String) -> Bool
    let onSetExpanded: (String, Bool) -> Void
    let onQuickLook: (String) -> Void
    let onUseForRestore: (String) -> Void

    var body: some View {
        List(selection: $selection) {
            RestoreBrowserNodeRows(nodes: roots, tree: self)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first {
                Button("Quick Look") {
                    onQuickLook(path)
                }
                Button("Use for Restore") {
                    onUseForRestore(path)
                }
            }
        } primaryAction: { paths in
            guard let path = paths.first else {
                return
            }
            if isDirectory(path) {
                expansionBinding(for: path).wrappedValue.toggle()
            } else {
                onQuickLook(path)
            }
        }
        .onKeyPress(.space, phases: .down) { _ in
            guard let selection else {
                return .ignored
            }
            onQuickLook(selection)
            return .handled
        }
    }

    fileprivate func expansionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { forceExpanded || expandedPaths.contains(path) },
            set: { isExpanded in
                guard !forceExpanded else {
                    return
                }
                onSetExpanded(path, isExpanded)
            }
        )
    }
}

private struct RestoreBrowserNodeRows: View {
    let nodes: [RestoreBrowserNode]
    let tree: RestoreBrowserTree

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: tree.expansionBinding(for: node.path)) {
                    if node.children.isEmpty {
                        if tree.loadingPaths.contains(node.path) {
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        } else if !tree.forceExpanded {
                            Text("No Items")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                    } else {
                        RestoreBrowserNodeRows(nodes: node.children, tree: tree)
                    }
                } label: {
                    RestoreBrowserNodeLabel(node: node, isLoading: tree.loadingPaths.contains(node.path))
                }
            } else {
                RestoreBrowserNodeLabel(node: node, isLoading: false)
            }
        }
        .listRowSeparator(.hidden)
    }
}

private struct RestoreBrowserNodeLabel: View {
    let node: RestoreBrowserNode
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(node.name, systemImage: restoreBrowserIconName(for: node.path, isDirectory: node.isDirectory))
                .lineLimit(1)
            if isLoading {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

func restoreBrowserIconName(for path: String, isDirectory: Bool) -> String {
    if isDirectory {
        return "folder"
    }
    return isTextLikeRestorePath(path) ? "doc.text" : "doc"
}

private let textLikeRestoreExtensions: Set<String> = [
    "bash", "c", "cc", "cfg", "conf", "cpp", "css", "env", "gitignore", "go",
    "h", "hpp", "html", "ini", "java", "js", "json", "jsx", "m", "markdown",
    "md", "mm", "pbxproj", "py", "rb", "rst", "sh", "sql", "swift",
    "swiftformat", "swiftlint", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh",
]

private let textLikeRestoreNames: Set<String> = [
    "brewfile", "dockerfile", "license", "makefile", "readme",
]

private func isTextLikeRestorePath(_ path: String) -> Bool {
    let fileName = (path as NSString).lastPathComponent.lowercased()
    if textLikeRestoreNames.contains(fileName) {
        return true
    }
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    return textLikeRestoreExtensions.contains(pathExtension)
}
