import SwiftUI

struct BaxterRestoreView: View {
    enum RestoreDestinationMode: String {
        case original
        case custom
    }

    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    let restoreRootDirectoryKey = "__root__"
    @State var restorePrefix = ""
    @State var restoreContains = ""
    @State var restorePath = ""
    @State var restoreToDir = ""
    @State var restoreOverwrite = false
    @State var restoreVerifyOnly = false
    @State var showRestoreAdvanced = false
    @State var restoreDestinationMode: RestoreDestinationMode = .original
    @State var showRestoreInspector = false
    @State var expandedBrowserPaths: Set<String> = []
    @State var hasAutoLoadedRestore = false
    @State var restoreSearchDebounceTask: Task<Void, Never>?
    @State var browserFilter = ""
    @State var selectedBrowserPath: String?
    @State var restoreBrowserIndex: RestoreBrowserIndex = .empty
    @State var restoreBrowserDerivedCache = RestoreBrowserDerivedCache()
    @State var restoreBrowserLoadCoordinator = RestoreBrowserLoadCoordinator()
    @State var restoreBrowserLoadTasks: [String: Task<Void, Never>] = [:]
    @State var restoreRootPrefix = ""
    @State var showRestoreConfirmation = false
    @State var showQuickLook = false

    var body: some View {
        restoreBrowserPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .inspector(isPresented: $showRestoreInspector) {
                restoreInspector
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
            }
            .navigationSubtitle(restoreSubtitle)
            .searchable(text: browserFilterBinding, prompt: "Search")
            .toolbar {
                restoreToolbar
            }
            .onAppear {
                if statusModel.snapshots.isEmpty && !statusModel.isSnapshotsBusy {
                    statusModel.fetchSnapshots()
                }
                refreshRestoreBrowserDerivedState()
                triggerInitialRestoreLoadIfNeeded()
            }
            .onChange(of: statusModel.selectedSnapshot) { _, _ in
                scheduleAutomaticRestoreSearch(immediate: true)
            }
            .onChange(of: restorePrefix) { _, _ in
                guard hasAutoLoadedRestore else {
                    return
                }
                scheduleAutomaticRestoreSearch()
            }
            .onChange(of: restoreContains) { _, _ in
                guard hasAutoLoadedRestore else {
                    return
                }
                scheduleAutomaticRestoreSearch()
            }
            .onChange(of: restoreActionStatusMessage) { _, message in
                if message != nil {
                    showRestoreInspector = true
                }
            }
            .onDisappear {
                restoreSearchDebounceTask?.cancel()
                restoreSearchDebounceTask = nil
                cancelRestoreBrowserLoadTasks()
            }
            .alert("Confirm Restore", isPresented: $showRestoreConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button(restoreVerifyOnly ? "Validate" : "Restore", role: restoreVerifyOnly ? nil : .destructive) {
                    statusModel.runRestore(
                        path: restorePath,
                        toDir: effectiveRestoreToDir,
                        overwrite: restoreOverwrite,
                        verifyOnly: restoreVerifyOnly,
                        snapshot: statusModel.selectedSnapshotRequestValue
                    )
                }
            } message: {
                Text(restoreConfirmationSummary)
            }
            .sheet(isPresented: $showQuickLook) {
                quickLookSheet
            }
    }

    private var restoreSubtitle: String {
        if isLoadingRestoreBrowser {
            return "Loading…"
        }
        let count = filteredRestoreBrowserNodeCount
        return count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    @ToolbarContentBuilder
    private var restoreToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Snapshot", selection: $statusModel.selectedSnapshot) {
                Text("Latest Snapshot").tag(BackupStatusModel.latestSnapshotSelection)
                ForEach(statusModel.snapshots, id: \.id) { snapshot in
                    Text(snapshotRowLabel(snapshot)).tag(snapshot.id)
                }
            }
            .disabled(statusModel.isSnapshotsBusy)
            .help("Choose the snapshot to browse")

            Button {
                statusModel.fetchSnapshots()
                scheduleAutomaticRestoreSearch(immediate: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(statusModel.isSnapshotsBusy)
            .help("Refresh snapshots")
        }

        ToolbarItem {
            if statusModel.isSnapshotsBusy || statusModel.isRestoreBusy {
                ProgressView()
                    .controlSize(.small)
                    .help(statusModel.isRestoreBusy ? "Restore in progress" : "Loading snapshots")
            }
        }

        ToolbarItem {
            Button {
                showRestoreInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showRestoreInspector ? "Hide the restore inspector" : "Show the restore inspector")
        }
    }

    private var restoreBrowserPanel: some View {
        Group {
            if filteredRestoreBrowserRoots.isEmpty {
                if isLoadingRestoreBrowser {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        restoreBrowserEmptyStateTitle,
                        systemImage: "tray",
                        description: Text(restoreSourceFailure ?? restoreBrowserEmptyStateMessage)
                    )
                }
            } else {
                RestoreBrowserTree(
                    roots: filteredRestoreBrowserRoots,
                    forceExpanded: isRestoreBrowserForceExpanded,
                    expandedPaths: expandedBrowserPaths,
                    loadingPaths: restoreBrowserLoadCoordinator.loadingDirectoryKeys,
                    selection: browserSelectionBinding,
                    isDirectory: { restoreBrowserIndex.isDirectoryByPath[$0] == true },
                    onSetExpanded: setBrowserNodeExpanded(path:isExpanded:),
                    onQuickLook: { path in
                        selectBrowserPath(path)
                        presentQuickLook()
                    },
                    onUseForRestore: { path in
                        selectBrowserPath(path)
                        showRestoreInspector = true
                    }
                )
            }
        }
    }

    private var restoreInspector: some View {
        Form {
            Section("Selection") {
                if let selectedPath = activeRestorePath {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((selectedPath as NSString).lastPathComponent)
                                .lineLimit(1)
                            Text(selectedPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: iconName(for: selectedPath))
                    }
                } else {
                    Text("Select a file or folder to restore.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Restore To", selection: $restoreDestinationMode) {
                    Text("Original Location").tag(RestoreDestinationMode.original)
                    Text("Another Folder").tag(RestoreDestinationMode.custom)
                }

                if restoreDestinationMode == .custom {
                    TextField("Folder", text: $restoreToDir, prompt: Text("Destination folder"))
                    Button("Choose…") {
                        chooseRestoreDestination()
                    }
                    .disabled(statusModel.isRestoreBusy)
                }

                Toggle("Overwrite existing files", isOn: $restoreOverwrite)
                    .disabled(restoreVerifyOnly)
            } header: {
                Text("Destination")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showRestoreConfirmation = true
                    } label: {
                        Text(restoreVerifyOnly ? "Validate" : "Restore")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canRunRestore)

                    if statusModel.isRestoreBusy {
                        ProgressView("Working…")
                            .controlSize(.small)
                    }

                    if let message = restoreActionStatusMessage {
                        Text(message)
                            .foregroundStyle(restoreMessageColor)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }

            Section {
                TextField("Path Prefix", text: $restorePrefix, prompt: Text("Optional"))
                TextField("Contains", text: $restoreContains, prompt: Text("Optional"))
            } header: {
                Text("Filter")
            } footer: {
                if let sourceNotice = restoreSourceNotice {
                    Text(sourceNotice)
                        .textSelection(.enabled)
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showRestoreAdvanced) {
                    Toggle("Validate only", isOn: $restoreVerifyOnly)
                    TextField("Path", text: $restorePath, prompt: Text("Manual path override"))
                    Button("Preview Target") {
                        statusModel.previewRestore(
                            path: restorePath,
                            toDir: effectiveRestoreToDir,
                            overwrite: restoreOverwrite,
                            snapshot: statusModel.selectedSnapshotRequestValue
                        )
                    }
                    .disabled(!canRunRestore)
                }
            } footer: {
                if showRestoreAdvanced {
                    Text("Validate only reads, decrypts and checks files without writing them. Preview Target shows where the selection would be restored.")
                }
            }

            if statusModel.lastRestoreAt != nil || statusModel.lastRestorePath != nil {
                Section("Last Restore") {
                    if let lastRestoreAt = statusModel.lastRestoreAt {
                        LabeledContent("Finished", value: lastRestoreAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let lastRestorePath = statusModel.lastRestorePath {
                        LabeledContent("Path") {
                            Text(lastRestorePath)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func snapshotRowLabel(_ snapshot: SnapshotSummary) -> String {
        let id = snapshot.id.count > 14 ? "\(snapshot.id.prefix(14))…" : snapshot.id
        return "\(id) (\(snapshot.entries))"
    }

    private var restoreConfirmationSummary: String {
        let source = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = effectiveRestoreToDir
        let snapshot = statusModel.selectedSnapshot == BackupStatusModel.latestSnapshotSelection
            ? "latest"
            : statusModel.selectedSnapshot
        let targetText = destination.isEmpty ? "original path" : destination
        return "Source: \(source)\nSnapshot: \(snapshot)\nDestination root: \(targetText)\nOverwrite: \(restoreOverwrite ? "yes" : "no")\nVerify only: \(restoreVerifyOnly ? "yes" : "no")"
    }

    var activeRestorePath: String? {
        if let selectedBrowserPath, !selectedBrowserPath.isEmpty {
            return selectedBrowserPath
        }
        let manualPath = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return manualPath.isEmpty ? nil : manualPath
    }
}
