import AppKit
import SwiftUI

extension BaxterRestoreView {
    var browserFilterBinding: Binding<String> {
        Binding(
            get: { browserFilter },
            set: { value in
                browserFilter = value
                refreshRestoreBrowserDerivedState()
            }
        )
    }

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
        restoreBrowserDerivedCache.state.rootNodes
    }

    var isLoadingRestoreBrowser: Bool {
        !restoreBrowserLoadCoordinator.loadingDirectoryKeys.isEmpty
    }

    var filteredRestoreBrowserPaths: [String] {
        restoreBrowserDerivedCache.state.visiblePaths
    }

    var isRestoreBrowserForceExpanded: Bool {
        !browserFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var renderedRestoreBrowserRows: [RestoreBrowserRenderedRow] {
        restoreBrowserRenderedRowsCache.rows
    }

    var filteredRestoreBrowserNodeCount: Int {
        restoreBrowserDerivedCache.state.visibleNodeCount
    }

    var isRestoreActionsPanelVisible: Bool {
        activeRestorePath != nil
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
        let previousSelection = selectedBrowserPath
        selectedBrowserPath = path
        restorePath = path
        guard previousSelection != path else {
            return
        }
        refreshRestoreBrowserDerivedState()
    }

    func clearBrowserSelection() {
        let hadSelection = selectedBrowserPath != nil
        selectedBrowserPath = nil
        restorePath = ""
        guard hadSelection else {
            return
        }
        refreshRestoreBrowserDerivedState()
    }

    func searchRestorePaths() {
        let query = currentRestoreBrowserQuery()
        cancelRestoreBrowserLoadTasks()
        selectedBrowserPath = nil
        restorePath = ""
        expandedBrowserPaths = []
        restoreBrowserIndex = .empty
        restoreRootPrefix = query.rootPrefix
        refreshRestoreBrowserDerivedState()
        restoreBrowserLoadCoordinator.reset(for: query)
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
        if restoreBrowserIndex.isDirectoryByPath[path] == true {
            return "folder"
        }
        return isTextLikeRestorePath(path) ? "doc.text" : "doc"
    }

    func iconColor(for path: String) -> Color {
        if restoreBrowserIndex.isDirectoryByPath[path] == true {
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

    func loadRestoreChildren(parentPath: String?, query: RestoreBrowserQuery? = nil) {
        let query = query ?? currentRestoreBrowserQuery()
        let directoryKey = parentPath ?? restoreRootDirectoryKey
        guard let loadToken = restoreBrowserLoadCoordinator.startLoad(
            directoryKey: directoryKey,
            query: query
        ) else {
            return
        }
        refreshRestoreBrowserDerivedState()

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
                        return
                    }
                    mergeRestorePaths(paths)
                    if let parentPath {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) child path(s) under \(parentPath)."
                    } else {
                        statusModel.restorePreviewMessage = "Loaded \(paths.count) path(s). Select a folder to load more."
                    }
                }
            } catch {
                await MainActor.run {
                    self.restoreBrowserLoadTasks[directoryKey] = nil
                    let accepted = self.restoreBrowserLoadCoordinator.completeLoad(loadToken, success: false)
                    if self.isCancelledRestoreBrowserLoad(error) {
                        return
                    }
                    guard accepted else {
                        return
                    }
                    refreshRestoreBrowserDerivedState()
                    statusModel.restorePreviewMessage = "Restore list failed: \(error.localizedDescription)"
                }
            }
        }
        restoreBrowserLoadTasks[directoryKey] = task
    }

    func mergeRestorePaths(_ paths: [String]) {
        restoreBrowserIndex = mergeRestoreBrowserIndex(restoreBrowserIndex, paths: paths)
        refreshRestoreBrowserDerivedState()
    }

    func setBrowserNodeExpanded(path: String, isExpanded: Bool) {
        if isExpanded {
            expandedBrowserPaths.insert(path)
            if restoreBrowserIndex.isDirectoryByPath[path] == true {
                loadRestoreChildren(parentPath: path, query: currentRestoreBrowserQuery())
            }
        } else {
            expandedBrowserPaths.remove(path)
        }
        refreshRestoreBrowserDerivedState()
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

    func refreshRestoreBrowserDerivedState() {
        var derivedCache = restoreBrowserDerivedCache
        derivedCache.resolve(
            index: restoreBrowserIndex,
            rootPrefix: restoreRootPrefix,
            query: browserFilter
        )
        var visibleRowsCache = restoreBrowserVisibleRowsCache
        visibleRowsCache.resolve(
            roots: derivedCache.state.rootNodes,
            treeRevision: restoreBrowserIndex.revision,
            rootPrefix: restoreRootPrefix,
            query: browserFilter,
            expandedPaths: expandedBrowserPaths,
            loadingDirectoryKeys: restoreBrowserLoadCoordinator.loadingDirectoryKeys,
            forceExpanded: isRestoreBrowserForceExpanded
        )
        var renderedRowsCache = restoreBrowserRenderedRowsCache
        renderedRowsCache.resolve(
            visibleRows: visibleRowsCache.rows,
            selectedPath: selectedBrowserPath
        )
        restoreBrowserDerivedCache = derivedCache
        restoreBrowserVisibleRowsCache = visibleRowsCache
        restoreBrowserRenderedRowsCache = renderedRowsCache
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
    let rows: [RestoreBrowserRenderedRow]
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
                        ForEach(rows) { row in
                            RestoreBrowserVisibleRowView(
                                renderedRow: row,
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

struct RestoreBrowserVisibleRowView: View, Equatable {
    let renderedRow: RestoreBrowserRenderedRow
    let forceExpanded: Bool
    let iconName: (String) -> String
    let iconColor: (String) -> Color
    let onSelect: (String) -> Void
    let onToggleExpansion: (String, Bool) -> Void
    let onQuickLook: (String) -> Void
    let onUseForRestore: (String) -> Void

    static func == (lhs: RestoreBrowserVisibleRowView, rhs: RestoreBrowserVisibleRowView) -> Bool {
        lhs.renderedRow == rhs.renderedRow &&
            lhs.forceExpanded == rhs.forceExpanded
    }

    private var row: RestoreBrowserVisibleRow {
        renderedRow.visibleRow
    }

    private var node: RestoreBrowserNode? {
        row.node
    }

    private var isExpanded: Bool {
        row.isExpanded
    }

    private var isSelected: Bool {
        renderedRow.isSelected
    }

    private var isLoading: Bool {
        row.isLoadingPlaceholder || row.isLoading
    }

    private var rowLeadingPadding: CGFloat {
        CGFloat(row.depth) * 12 + 4
    }

    private var loadingPlaceholderLeadingPadding: CGFloat {
        CGFloat(row.depth) * 12 + 20
    }

    var body: some View {
        Group {
            if row.isLoadingPlaceholder {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, loadingPlaceholderLeadingPadding)
                .padding(.vertical, 1)
            } else if let node {
                HStack(spacing: 4) {
                    expansionToggle(for: node)

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
            }
        }
    }

    @ViewBuilder
    private func expansionToggle(for node: RestoreBrowserNode) -> some View {
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
