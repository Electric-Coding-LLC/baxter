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
                        .foregroundStyle(iconColor(for: previewPath))
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
        !restoreBrowserLoadCoordinator.loadingDirectoryKeys.isEmpty
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
        selectedBrowserPath = path
        restorePath = path
    }

    func clearBrowserSelection() {
        selectedBrowserPath = nil
        restorePath = ""
    }

    func searchRestorePaths() {
        let query = currentRestoreBrowserQuery()
        cancelRestoreBrowserLoadTasks()
        restoreIndexBuildGeneration += 1
        restoreIndexBuildTask?.cancel()
        restoreIndexBuildTask = nil
        selectedBrowserPath = nil
        restorePath = ""
        expandedBrowserPaths = []
        restoreBrowserRoots = []
        restorePathKinds = [:]
        loadedRestorePaths = []
        restoreRootPrefix = query.rootPrefix
        restoreBrowserLoadCoordinator.reset(for: query)
        syncRestoreBrowserWorkState()
        loadRestoreChildren(parentPath: nil, query: query)
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
        if restorePathKinds[path] == true {
            return "folder"
        }
        return isTextLikeRestorePath(path) ? "doc.text" : "doc"
    }

    func iconColor(for path: String) -> Color {
        if restorePathKinds[path] == true {
            return Color(nsColor: .systemBlue)
        }
        return .secondary
    }

    func currentRestoreBrowserQuery() -> RestoreBrowserQuery {
        RestoreBrowserQuery(
            rootPrefix: resolvedRestoreRootPrefix(),
            contains: restoreContains,
            snapshot: statusModel.selectedSnapshotRequestValue
        )
    }

    func cancelRestoreBrowserLoadTasks() {
        for task in restoreBrowserLoadTasks.values {
            task.cancel()
        }
        restoreBrowserLoadTasks = [:]
        restoreBrowserLoadCoordinator.cancelAllLoads()
        syncRestoreBrowserWorkState()
    }

    func syncRestoreBrowserWorkState() {
        isIndexingRestorePaths =
            restoreIndexBuildTask != nil || !restoreBrowserLoadCoordinator.loadingDirectoryKeys.isEmpty
    }

    func isCancelledRestoreBrowserLoad(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    func indexRestorePaths(_ restorePaths: [String]) {
        restoreIndexBuildGeneration += 1
        restoreIndexBuildTask?.cancel()
        restoreIndexBuildTask = nil

        if restorePaths.isEmpty {
            restoreBrowserRoots = []
            restorePathKinds = [:]
            syncRestoreBrowserWorkState()
            return
        }

        let generation = restoreIndexBuildGeneration

        let task = Task.detached(priority: .userInitiated) {
            let index = buildRestoreBrowserIndex(paths: restorePaths, maxPaths: 0)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self.restoreIndexBuildGeneration == generation else {
                    return
                }
                self.restoreBrowserRoots = index.rootNodes
                self.restorePathKinds = index.isDirectoryByPath
                self.restoreIndexBuildTask = nil
                self.syncRestoreBrowserWorkState()
            }
        }
        restoreIndexBuildTask = task
        syncRestoreBrowserWorkState()
    }

    func loadRestoreChildren(parentPath: String?, query: RestoreBrowserQuery? = nil) {
        let query = query ?? currentRestoreBrowserQuery()
        let directoryKey = parentPath ?? restoreRootDirectoryKey
        guard let loadToken = restoreBrowserLoadCoordinator.startLoad(
            directoryKey: directoryKey,
            query: query
        ) else {
            return
        }
        syncRestoreBrowserWorkState()

        let task = Task {
            do {
                let prefix = parentPath ?? query.rootPrefix
                let paths = try await statusModel.fetchRestorePaths(
                    prefix: prefix,
                    contains: query.contains,
                    snapshot: query.snapshot,
                    childrenOnly: true
                )
                await MainActor.run {
                    self.restoreBrowserLoadTasks[directoryKey] = nil
                    guard self.restoreBrowserLoadCoordinator.completeLoad(loadToken, success: true) else {
                        self.syncRestoreBrowserWorkState()
                        return
                    }
                    mergeRestorePaths(paths)
                    if let parentPath {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) child path(s) under \(parentPath)."
                    } else {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) path(s). Select a folder to load more."
                    }
                    self.syncRestoreBrowserWorkState()
                }
            } catch {
                await MainActor.run {
                    self.restoreBrowserLoadTasks[directoryKey] = nil
                    let accepted = self.restoreBrowserLoadCoordinator.completeLoad(loadToken, success: false)
                    if self.isCancelledRestoreBrowserLoad(error) {
                        self.syncRestoreBrowserWorkState()
                        return
                    }
                    guard accepted else {
                        self.syncRestoreBrowserWorkState()
                        return
                    }
                    statusModel.restorePreviewMessage = "Restore list failed: \(error.localizedDescription)"
                    self.syncRestoreBrowserWorkState()
                }
            }
        }
        restoreBrowserLoadTasks[directoryKey] = task
    }

    func mergeRestorePaths(_ paths: [String]) {
        for path in paths {
            loadedRestorePaths.insert(path)
        }
        indexRestorePaths(Array(loadedRestorePaths))
    }

    func setBrowserNodeExpanded(path: String, isExpanded: Bool) {
        if isExpanded {
            expandedBrowserPaths.insert(path)
            if restorePathKinds[path] == true {
                loadRestoreChildren(parentPath: path, query: currentRestoreBrowserQuery())
            }
        } else {
            expandedBrowserPaths.remove(path)
        }
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

struct RestoreBrowserTree: View {
    let roots: [RestoreBrowserNode]
    let selectedPath: String?
    @Binding var expandedPaths: Set<String>
    let loadingDirectoryKeys: Set<String>
    let forceExpanded: Bool
    let iconName: (String) -> String
    let iconColor: (String) -> Color
    let onClearSelection: () -> Void
    let onSelect: (String) -> Void
    let onToggleExpansion: (String, Bool) -> Void
    let onQuickLook: (String) -> Void
    let onUseForRestore: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onClearSelection()
                        }

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(roots) { node in
                            RestoreBrowserTreeRow(
                                node: node,
                                depth: 0,
                                selectedPath: selectedPath,
                                expandedPaths: $expandedPaths,
                                loadingDirectoryKeys: loadingDirectoryKeys,
                                forceExpanded: forceExpanded,
                                iconName: iconName,
                                iconColor: iconColor,
                                onSelect: onSelect,
                                onToggleExpansion: onToggleExpansion,
                                onQuickLook: onQuickLook,
                                onUseForRestore: onUseForRestore
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RestoreBrowserTreeRow: View {
    let node: RestoreBrowserNode
    let depth: Int
    let selectedPath: String?
    @Binding var expandedPaths: Set<String>
    let loadingDirectoryKeys: Set<String>
    let forceExpanded: Bool
    let iconName: (String) -> String
    let iconColor: (String) -> Color
    let onSelect: (String) -> Void
    let onToggleExpansion: (String, Bool) -> Void
    let onQuickLook: (String) -> Void
    let onUseForRestore: (String) -> Void

    private var isExpanded: Bool {
        node.isDirectory && (forceExpanded || expandedPaths.contains(node.path))
    }

    private var isSelected: Bool {
        selectedPath == node.path
    }

    private var isLoading: Bool {
        loadingDirectoryKeys.contains(node.path)
    }

    private var rowLeadingPadding: CGFloat {
        CGFloat(depth) * 12 + 4
    }

    private var childLeadingPadding: CGFloat {
        CGFloat(depth + 1) * 12 + 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                expansionToggle

                Image(systemName: iconName(node.path))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor(node.path))

                Text(node.name)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 21)
            .padding(.leading, rowLeadingPadding)
            .padding(.trailing, 10)
            .padding(.vertical, 1)
            .background(
                isSelected ? Color.accentColor.opacity(0.24) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if node.isDirectory && !isExpanded && !forceExpanded {
                    onToggleExpansion(node.path, true)
                }
                onSelect(node.path)
            }
            .contextMenu {
                Button("Quick Look") {
                    onQuickLook(node.path)
                }
                Button("Use for Restore") {
                    onUseForRestore(node.path)
                }
            }

            if node.isDirectory && isExpanded {
                if node.children.isEmpty && isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, childLeadingPadding)
                    .padding(.vertical, 1)
                } else {
                    ForEach(node.children) { child in
                        RestoreBrowserTreeRow(
                            node: child,
                            depth: depth + 1,
                            selectedPath: selectedPath,
                            expandedPaths: $expandedPaths,
                            loadingDirectoryKeys: loadingDirectoryKeys,
                            forceExpanded: forceExpanded,
                            iconName: iconName,
                            iconColor: iconColor,
                            onSelect: onSelect,
                            onToggleExpansion: onToggleExpansion,
                            onQuickLook: onQuickLook,
                            onUseForRestore: onUseForRestore
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var expansionToggle: some View {
        if node.isDirectory {
            Button {
                guard !forceExpanded else {
                    return
                }
                onToggleExpansion(node.path, !isExpanded)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(width: 18, height: 18)
        }
    }
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
