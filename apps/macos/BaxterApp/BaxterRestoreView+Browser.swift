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

    var browserSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedBrowserPath },
            set: { path in
                if let path {
                    selectBrowserPath(path)
                } else {
                    clearBrowserSelection()
                }
            }
        )
    }

    var filteredRestoreBrowserNodeCount: Int {
        restoreBrowserDerivedCache.state.visibleNodeCount
    }

    var hasLoadedRestoreBrowserPaths: Bool {
        !restoreBrowserIndex.rootNodes.isEmpty
    }

    var restoreBrowserEmptyStateTitle: String {
        if selectedSnapshotIsEmpty {
            return statusModel.selectedSnapshot == BackupStatusModel.latestSnapshotSelection
                ? "Latest snapshot is empty"
                : "Selected snapshot is empty"
        }
        return hasLoadedRestoreBrowserPaths ? "No matching paths" : "No backup contents available"
    }

    var restoreBrowserEmptyStateMessage: String {
        if selectedSnapshotIsEmpty {
            if statusModel.selectedSnapshot == BackupStatusModel.latestSnapshotSelection && hasOlderSnapshotsWithContents {
                return "The newest backup completed with 0 restorable paths. Choose an older snapshot with contents in the toolbar."
            }
            return "This snapshot has 0 restorable paths. Choose another snapshot in the toolbar or run a backup with files in scope."
        }
        if hasLoadedRestoreBrowserPaths {
            return "Change the search or the filter in the inspector and results will refresh automatically."
        }
        return "Run a backup or connect an existing backup set, then refresh Restore."
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

    var restoreSourceFailure: String? {
        for message in [statusModel.snapshotsMessage, restoreBrowserStatusMessage] {
            guard let message, !message.isEmpty else {
                continue
            }
            let lowered = message.lowercased()
            if lowered.contains("failed") || lowered.contains("error") {
                return message
            }
        }
        return nil
    }

    var restoreSourceNotice: String? {
        if let failure = restoreSourceFailure {
            return failure
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

    var selectedSnapshotIsEmpty: Bool {
        if statusModel.selectedSnapshot == BackupStatusModel.latestSnapshotSelection {
            return (statusModel.snapshots.first?.entries ?? 0) == 0 && !statusModel.snapshots.isEmpty
        }
        return statusModel.selectedSnapshotSummary?.entries == 0
    }

    var hasOlderSnapshotsWithContents: Bool {
        statusModel.snapshots.dropFirst().contains(where: { $0.entries > 0 })
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
        restoreBrowserIconName(for: path, isDirectory: restoreBrowserIndex.isDirectoryByPath[path] == true)
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
        restoreBrowserDerivedCache = derivedCache
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
