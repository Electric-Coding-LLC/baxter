import AppKit
import SwiftUI

extension BaxterRestoreView {
    @ViewBuilder
    var quickLookSheet: some View {
        if let previewPath = activeRestorePath {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: iconName(for: previewPath))
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(restorePathName(previewPath))
                            .font(.title3.weight(.semibold))
                        Text(restoreParentPath(previewPath))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use for Restore") {
                        restorePath = previewPath
                        showQuickLook = false
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                Text("Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(previewPath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Spacer()
                    Button("Close") {
                        showQuickLook = false
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 560, minHeight: 320)
        } else {
            VStack(spacing: 10) {
                Text("No item selected")
                    .font(.headline)
                Button("Close") {
                    showQuickLook = false
                }
            }
            .padding(16)
            .frame(minWidth: 380, minHeight: 220)
        }
    }

    var filteredRestoreBrowserRoots: [RestoreBrowserNode] {
        filterRestoreBrowserNodes(scopedRestoreBrowserRoots, query: browserFilter)
    }

    var isLoadingRestoreBrowser: Bool {
        !loadingRestoreDirectoryPaths.isEmpty
    }

    var filteredRestoreBrowserPaths: [String] {
        flattenRestoreBrowserNodePaths(filteredRestoreBrowserRoots)
    }

    var isRestoreActionsPanelVisible: Bool {
        activeRestorePath != nil
    }

    var scopedRestoreBrowserRoots: [RestoreBrowserNode] {
        guard !restoreRootPrefix.isEmpty, restoreRootPrefix != "/" else {
            return restoreBrowserRoots
        }
        guard let scopedRoot = findRestoreBrowserNode(
            path: restoreRootPrefix,
            nodes: restoreBrowserRoots
        ) else {
            return restoreBrowserRoots
        }
        return [scopedRoot]
    }

    var restoreMessageColor: Color {
        let message = restoreActionStatusMessage?.lowercased() ?? ""
        if message.contains("failed") || message.contains("error") {
            return .red
        }
        return .secondary
    }

    var effectiveRestoreToDir: String {
        guard restoreDestinationMode == .custom else {
            return ""
        }
        return restoreToDir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canRunRestore: Bool {
        let source = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statusModel.isRestoreBusy, !source.isEmpty else {
            return false
        }
        if restoreDestinationMode == .custom {
            return !effectiveRestoreToDir.isEmpty
        }
        return true
    }

    var restoreActionStatusMessage: String? {
        guard let message = statusModel.restorePreviewMessage, !message.isEmpty else {
            return nil
        }
        return isBrowserStatusMessage(message) ? nil : message
    }

    var restoreBrowserStatusMessage: String? {
        guard let message = statusModel.restorePreviewMessage, !message.isEmpty else {
            return nil
        }
        return isBrowserStatusMessage(message) ? message : nil
    }

    var restoreSourceNotice: String? {
        if let snapshotsMessage = statusModel.snapshotsMessage, !snapshotsMessage.isEmpty {
            let lowered = snapshotsMessage.lowercased()
            if lowered.contains("failed") || lowered.contains("error") {
                return snapshotsMessage
            }
        }
        if let browserMessage = restoreBrowserStatusMessage, !browserMessage.isEmpty {
            return browserMessage
        }
        return nil
    }

    func isBrowserStatusMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.hasPrefix("loaded ") || lowered.hasPrefix("found ") || lowered.hasPrefix("restore list")
    }

    func presentQuickLook() {
        if selectedBrowserPath == nil, let firstPath = filteredRestoreBrowserPaths.first {
            selectBrowserPath(firstPath)
        }
        guard activeRestorePath != nil else {
            return
        }
        showQuickLook = true
    }

    func selectBrowserPath(_ path: String) {
        if isRestorePlaceholderPath(path) {
            return
        }
        selectedBrowserPath = path
        restorePath = path
        if restorePathKinds[path] == true {
            loadRestoreChildren(parentPath: path)
        }
    }

    func searchRestorePaths() {
        selectedBrowserPath = nil
        restorePath = ""
        restoreBrowserRoots = []
        restorePathKinds = [:]
        loadedRestorePaths = []
        loadedRestoreDirectoryPaths = []
        loadingRestoreDirectoryPaths = []
        restoreRootPrefix = resolvedRestoreRootPrefix()
        loadRestoreChildren(parentPath: nil)
    }

    func triggerInitialRestoreLoadIfNeeded() {
        guard !hasAutoLoadedRestore else {
            return
        }
        hasAutoLoadedRestore = true
        scheduleAutomaticRestoreSearch(immediate: true)
    }

    func scheduleAutomaticRestoreSearch(immediate: Bool = false) {
        restoreSearchDebounceTask?.cancel()
        restoreSearchDebounceTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                searchRestorePaths()
                restoreSearchDebounceTask = nil
            }
        }
    }

    func iconName(for path: String) -> String {
        restorePathKinds[path] == true ? "folder" : "doc"
    }

    func indexRestorePaths(_ restorePaths: [String]) {
        if restorePaths.isEmpty {
            restoreBrowserRoots = []
            restorePathKinds = [:]
            isIndexingRestorePaths = false
            return
        }

        Task.detached(priority: .userInitiated) {
            let index = buildRestoreBrowserIndex(paths: restorePaths, maxPaths: 0)
            await MainActor.run {
                self.restoreBrowserRoots = index.rootNodes
                self.restorePathKinds = index.isDirectoryByPath
                self.isIndexingRestorePaths = false
            }
        }
    }

    func loadRestoreChildren(parentPath: String?) {
        let directoryKey = parentPath ?? restoreRootDirectoryKey
        if loadingRestoreDirectoryPaths.contains(directoryKey) || loadedRestoreDirectoryPaths.contains(directoryKey) {
            return
        }
        loadingRestoreDirectoryPaths.insert(directoryKey)
        isIndexingRestorePaths = true

        Task {
            do {
                let prefix = parentPath ?? restoreRootPrefix
                let paths = try await statusModel.fetchRestorePaths(
                    prefix: prefix,
                    contains: restoreContains,
                    snapshot: statusModel.selectedSnapshotRequestValue,
                    childrenOnly: true
                )
                await MainActor.run {
                    loadingRestoreDirectoryPaths.remove(directoryKey)
                    loadedRestoreDirectoryPaths.insert(directoryKey)
                    mergeRestorePaths(paths)
                    if let parentPath {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) child path(s) under \(parentPath)."
                    } else {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) path(s). Select a folder to load more."
                    }
                }
            } catch {
                await MainActor.run {
                    loadingRestoreDirectoryPaths.remove(directoryKey)
                    isIndexingRestorePaths = false
                    statusModel.restorePreviewMessage = "Restore list failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func mergeRestorePaths(_ paths: [String]) {
        for path in paths {
            loadedRestorePaths.insert(path)
        }
        indexRestorePaths(Array(loadedRestorePaths))
    }

    func decorateRestoreNodesForLazyExpansion(_ nodes: [RestoreBrowserNode]) -> [RestoreBrowserNode] {
        nodes.map(decorateRestoreNodeForLazyExpansion(_:))
    }

    func decorateRestoreNodeForLazyExpansion(_ node: RestoreBrowserNode) -> RestoreBrowserNode {
        if node.isPlaceholder {
            return node
        }

        let decoratedChildren = node.children.map(decorateRestoreNodeForLazyExpansion(_:))
        guard node.isDirectory else {
            return RestoreBrowserNode(
                path: node.path,
                name: node.name,
                isDirectory: node.isDirectory,
                children: decoratedChildren
            )
        }

        let shouldInjectPlaceholder = !loadedRestoreDirectoryPaths.contains(node.path) && !loadingRestoreDirectoryPaths.contains(node.path)
        if shouldInjectPlaceholder {
            return RestoreBrowserNode(
                path: node.path,
                name: node.name,
                isDirectory: node.isDirectory,
                children: [makeRestorePlaceholderNode(parentPath: node.path)]
            )
        }

        return RestoreBrowserNode(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            children: decoratedChildren
        )
    }

    func makeRestorePlaceholderNode(parentPath: String) -> RestoreBrowserNode {
        RestoreBrowserNode(
            path: "\(restorePlaceholderPrefix)\(parentPath)",
            name: "Loading...",
            isDirectory: false,
            children: [],
            isPlaceholder: true
        )
    }

    func isRestorePlaceholderPath(_ path: String) -> Bool {
        path.hasPrefix(restorePlaceholderPrefix)
    }

    func restoreParentPathForPlaceholder(_ path: String) -> String? {
        guard isRestorePlaceholderPath(path) else {
            return nil
        }
        let parentPath = String(path.dropFirst(restorePlaceholderPrefix.count))
        return parentPath.isEmpty ? nil : parentPath
    }

    func loadRestoreChildrenFromPlaceholder(_ path: String) {
        guard let parentPath = restoreParentPathForPlaceholder(path) else {
            return
        }
        loadRestoreChildren(parentPath: parentPath)
    }

    func normalizedRestorePrefix(_ rawPrefix: String) -> String {
        var value = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "/" {
            return value
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    func resolvedRestoreRootPrefix() -> String {
        let explicitPrefix = normalizedRestorePrefix(restorePrefix)
        if !explicitPrefix.isEmpty {
            return explicitPrefix
        }

        let backupRoots = settingsModel.backupRoots
            .map(normalizedRestorePrefix(_:))
            .filter { !$0.isEmpty }
        if backupRoots.count == 1 {
            return backupRoots[0]
        }
        return ""
    }

    func findRestoreBrowserNode(path: String, nodes: [RestoreBrowserNode]) -> RestoreBrowserNode? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let found = findRestoreBrowserNode(path: path, nodes: node.children) {
                return found
            }
        }
        return nil
    }

    func chooseRestoreDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Choose"
        panel.message = "Select a destination root for restore output."

        if !restoreToDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: restoreToDir)
        }

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.urls.first else {
            return
        }
        restoreDestinationMode = .custom
        restoreToDir = selectedURL.path
    }
}
