import Foundation

struct RestoreBrowserVisibleRow: Identifiable, Equatable {
    let id: String
    let path: String
    let node: RestoreBrowserNode?
    let depth: Int
    let isExpanded: Bool
    let isLoading: Bool
    let isLoadingPlaceholder: Bool
}

struct RestoreBrowserVisibleRowsCache {
    private var key: RestoreBrowserVisibleRowsCacheKey?
    private(set) var rows: [RestoreBrowserVisibleRow] = []

    mutating func resolve(
        roots: [RestoreBrowserNode],
        treeRevision: Int,
        rootPrefix: String,
        query: String,
        expandedPaths: Set<String>,
        loadingDirectoryKeys: Set<String>,
        forceExpanded: Bool
    ) {
        let nextKey = RestoreBrowserVisibleRowsCacheKey(
            treeRevision: treeRevision,
            rootPrefix: rootPrefix,
            query: query,
            expandedPaths: expandedPaths,
            loadingDirectoryKeys: loadingDirectoryKeys,
            forceExpanded: forceExpanded
        )
        guard key != nextKey else {
            return
        }

        key = nextKey
        rows = buildRestoreBrowserVisibleRows(
            roots: roots,
            expandedPaths: expandedPaths,
            loadingDirectoryKeys: loadingDirectoryKeys,
            forceExpanded: forceExpanded
        )
    }
}

private struct RestoreBrowserVisibleRowsCacheKey: Equatable {
    let treeRevision: Int
    let rootPrefix: String
    let query: String
    let expandedPaths: Set<String>
    let loadingDirectoryKeys: Set<String>
    let forceExpanded: Bool
}

func buildRestoreBrowserVisibleRows(
    roots: [RestoreBrowserNode],
    expandedPaths: Set<String>,
    loadingDirectoryKeys: Set<String>,
    forceExpanded: Bool
) -> [RestoreBrowserVisibleRow] {
    var rows: [RestoreBrowserVisibleRow] = []
    appendRestoreBrowserVisibleRows(
        roots,
        depth: 0,
        expandedPaths: expandedPaths,
        loadingDirectoryKeys: loadingDirectoryKeys,
        forceExpanded: forceExpanded,
        into: &rows
    )
    return rows
}

private func appendRestoreBrowserVisibleRows(
    _ nodes: [RestoreBrowserNode],
    depth: Int,
    expandedPaths: Set<String>,
    loadingDirectoryKeys: Set<String>,
    forceExpanded: Bool,
    into rows: inout [RestoreBrowserVisibleRow]
) {
    for node in nodes {
        let isExpanded = node.isDirectory && (forceExpanded || expandedPaths.contains(node.path))
        let isLoading = loadingDirectoryKeys.contains(node.path)
        rows.append(
            RestoreBrowserVisibleRow(
                id: node.path,
                path: node.path,
                node: node,
                depth: depth,
                isExpanded: isExpanded,
                isLoading: isLoading,
                isLoadingPlaceholder: false
            )
        )

        guard node.isDirectory, isExpanded else {
            continue
        }

        if node.children.isEmpty && isLoading {
            rows.append(
                RestoreBrowserVisibleRow(
                    id: "\(node.path)#loading",
                    path: node.path,
                    node: nil,
                    depth: depth + 1,
                    isExpanded: false,
                    isLoading: true,
                    isLoadingPlaceholder: true
                )
            )
            continue
        }

        appendRestoreBrowserVisibleRows(
            node.children,
            depth: depth + 1,
            expandedPaths: expandedPaths,
            loadingDirectoryKeys: loadingDirectoryKeys,
            forceExpanded: forceExpanded,
            into: &rows
        )
    }
}
