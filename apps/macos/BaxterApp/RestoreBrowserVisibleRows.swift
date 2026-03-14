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

struct RestoreBrowserRenderedRow: Identifiable, Equatable {
    let id: String
    let visibleRow: RestoreBrowserVisibleRow
    var isSelected: Bool

    var path: String { visibleRow.path }
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

        if let currentKey = key,
           let updatedRows = incrementallyResolve(
               from: currentKey,
               to: nextKey,
               roots: roots
           ) {
            key = nextKey
            rows = updatedRows
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

    private func incrementallyResolve(
        from currentKey: RestoreBrowserVisibleRowsCacheKey,
        to nextKey: RestoreBrowserVisibleRowsCacheKey,
        roots: [RestoreBrowserNode]
    ) -> [RestoreBrowserVisibleRow]? {
        guard let toggledPaths = currentKey.incrementalTransitionPaths(to: nextKey) else {
            return nil
        }

        var updatedRows = rows
        for toggledPath in toggledPaths.sorted(by: { lhs, rhs in
            let lhsIndex = updatedRows.firstIndex(where: { row in
                !row.isLoadingPlaceholder && row.path == lhs
            }) ?? Int.max
            let rhsIndex = updatedRows.firstIndex(where: { row in
                !row.isLoadingPlaceholder && row.path == rhs
            }) ?? Int.max
            if lhsIndex == rhsIndex {
                return lhs < rhs
            }
            return lhsIndex < rhsIndex
        }) {
            guard let nextRows = applyIncrementalTransition(
                for: toggledPath,
                to: nextKey,
                roots: roots,
                rows: updatedRows
            ) else {
                return nil
            }
            updatedRows = nextRows
        }

        return updatedRows
    }

    private func applyIncrementalTransition(
        for toggledPath: String,
        to nextKey: RestoreBrowserVisibleRowsCacheKey,
        roots: [RestoreBrowserNode],
        rows: [RestoreBrowserVisibleRow]
    ) -> [RestoreBrowserVisibleRow]? {
        guard let rowIndex = rows.firstIndex(where: { row in
            !row.isLoadingPlaceholder && row.path == toggledPath
        }) else {
            // Hidden descendants can change expansion state without affecting visible rows,
            // but root-level misses are ambiguous and should fall back to a rebuild.
            guard rows.contains(where: { row in
                !row.isLoadingPlaceholder && isAncestorRestoreBrowserPath(row.path, of: toggledPath)
            }) else {
                return nil
            }
            return rows
        }

        let currentRow = rows[rowIndex]
        guard let node = findRestoreBrowserNode(path: toggledPath, nodes: roots),
              node.isDirectory else {
            return nil
        }

        var updatedRows = rows
        updatedRows[rowIndex] = RestoreBrowserVisibleRow(
            id: currentRow.id,
            path: currentRow.path,
            node: node,
            depth: currentRow.depth,
            isExpanded: nextKey.expandedPaths.contains(toggledPath),
            isLoading: nextKey.loadingDirectoryKeys.contains(toggledPath),
            isLoadingPlaceholder: false
        )

        let descendantRange = visibleDescendantRange(
            rowIndex: rowIndex,
            rows: updatedRows
        )
        updatedRows.removeSubrange(descendantRange)

        guard nextKey.expandedPaths.contains(toggledPath) else {
            return updatedRows
        }

        let descendants = buildRestoreBrowserVisibleDescendants(
            for: node,
            parentDepth: currentRow.depth,
            expandedPaths: nextKey.expandedPaths,
            loadingDirectoryKeys: nextKey.loadingDirectoryKeys,
            forceExpanded: nextKey.forceExpanded
        )
        updatedRows.insert(contentsOf: descendants, at: rowIndex + 1)
        return updatedRows
    }
}

struct RestoreBrowserRenderedRowsCache {
    private var visibleRows: [RestoreBrowserVisibleRow] = []
    private var selectableRowIndexByPath: [String: Int] = [:]
    private var selectedPath: String?
    private(set) var rows: [RestoreBrowserRenderedRow] = []

    mutating func resolve(visibleRows: [RestoreBrowserVisibleRow], selectedPath: String?) {
        if self.visibleRows == visibleRows {
            updateSelection(from: self.selectedPath, to: selectedPath)
            return
        }

        self.visibleRows = visibleRows
        self.selectedPath = selectedPath
        rows = visibleRows.map { visibleRow in
            RestoreBrowserRenderedRow(
                id: visibleRow.id,
                visibleRow: visibleRow,
                isSelected: !visibleRow.isLoadingPlaceholder && visibleRow.path == selectedPath
            )
        }
        selectableRowIndexByPath = [:]
        for (index, row) in rows.enumerated() where !row.visibleRow.isLoadingPlaceholder {
            selectableRowIndexByPath[row.path] = index
        }
    }

    private mutating func updateSelection(from previousPath: String?, to nextPath: String?) {
        guard previousPath != nextPath else {
            return
        }

        if let previousPath, let index = selectableRowIndexByPath[previousPath] {
            rows[index].isSelected = false
        }
        if let nextPath, let index = selectableRowIndexByPath[nextPath] {
            rows[index].isSelected = true
        }
        selectedPath = nextPath
    }
}

private struct RestoreBrowserVisibleRowsCacheKey: Equatable {
    let treeRevision: Int
    let rootPrefix: String
    let query: String
    let expandedPaths: Set<String>
    let loadingDirectoryKeys: Set<String>
    let forceExpanded: Bool

    func incrementalTransitionPaths(to next: RestoreBrowserVisibleRowsCacheKey) -> [String]? {
        let changedPaths = expandedPaths.symmetricDifference(next.expandedPaths)
        guard canIncrementallyTransition(to: next, changedPaths: changedPaths) else {
            return nil
        }

        return changedPaths.filter { candidate in
            !changedPaths.contains(where: { other in
                other != candidate && isAncestorRestoreBrowserPath(other, of: candidate)
            })
        }
    }

    private func canIncrementallyTransition(
        to next: RestoreBrowserVisibleRowsCacheKey,
        changedPaths: Set<String>
    ) -> Bool {
        guard treeRevision == next.treeRevision,
              rootPrefix == next.rootPrefix,
              query == next.query,
              forceExpanded == next.forceExpanded,
              forceExpanded == false,
              !changedPaths.isEmpty else {
            return false
        }

        let loadingDelta = loadingDirectoryKeys
            .symmetricDifference(next.loadingDirectoryKeys)
        return loadingDelta.isSubset(of: changedPaths)
    }
}

private func isAncestorRestoreBrowserPath(_ candidate: String, of path: String) -> Bool {
    guard candidate != path else {
        return false
    }
    guard path.hasPrefix(candidate) else {
        return false
    }
    if candidate == "/" {
        return path.hasPrefix("/")
    }
    return path.dropFirst(candidate.count).first == "/"
}

private func visibleDescendantRange(
    rowIndex: Int,
    rows: [RestoreBrowserVisibleRow]
) -> Range<Int> {
    let baseDepth = rows[rowIndex].depth
    var endIndex = rowIndex + 1
    while endIndex < rows.count, rows[endIndex].depth > baseDepth {
        endIndex += 1
    }
    return (rowIndex + 1)..<endIndex
}

private func buildRestoreBrowserVisibleDescendants(
    for node: RestoreBrowserNode,
    parentDepth: Int,
    expandedPaths: Set<String>,
    loadingDirectoryKeys: Set<String>,
    forceExpanded: Bool
) -> [RestoreBrowserVisibleRow] {
    guard node.isDirectory else {
        return []
    }
    if node.children.isEmpty, loadingDirectoryKeys.contains(node.path) {
        return [
            RestoreBrowserVisibleRow(
                id: "\(node.path)#loading",
                path: node.path,
                node: nil,
                depth: parentDepth + 1,
                isExpanded: false,
                isLoading: true,
                isLoadingPlaceholder: true
            )
        ]
    }

    var rows: [RestoreBrowserVisibleRow] = []
    appendRestoreBrowserVisibleRows(
        node.children,
        depth: parentDepth + 1,
        expandedPaths: expandedPaths,
        loadingDirectoryKeys: loadingDirectoryKeys,
        forceExpanded: forceExpanded,
        into: &rows
    )
    return rows
}

private func findRestoreBrowserNode(
    path: String,
    nodes: [RestoreBrowserNode]
) -> RestoreBrowserNode? {
    for node in nodes {
        if node.path == path {
            return node
        }
        if let match = findRestoreBrowserNode(path: path, nodes: node.children) {
            return match
        }
    }
    return nil
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
