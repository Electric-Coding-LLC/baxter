import SwiftUI

struct BaxterRestoreView: View {
    enum RestoreDestinationMode: String {
        case original
        case custom
    }

    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    var embedded: Bool = false
    let restoreRootDirectoryKey = "__root__"
    @State var restorePrefix = ""
    @State var restoreContains = ""
    @State var restorePath = ""
    @State var restoreToDir = ""
    @State var restoreOverwrite = false
    @State var restoreVerifyOnly = false
    @State var showRestoreAdvanced = false
    @State var restoreDestinationMode: RestoreDestinationMode = .original
    @State var isSourceColumnVisible = false
    @State var expandedBrowserPaths: Set<String> = []
    @State var hasAutoLoadedRestore = false
    @State var restoreSearchDebounceTask: Task<Void, Never>?
    @State var browserFilter = ""
    @State var selectedBrowserPath: String?
    @State var restoreBrowserIndex: RestoreBrowserIndex = .empty
    @State var restoreBrowserLoadCoordinator = RestoreBrowserLoadCoordinator()
    @State var restoreBrowserLoadTasks: [String: Task<Void, Never>] = [:]
    @State var restoreRootPrefix = ""
    @State var showRestoreConfirmation = false
    @State var showQuickLook = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            restoreTitle
            restoreToolbar
            Divider()
            restoreMainLayout
        }
        .padding(embedded ? 0 : 8)
        .frame(minWidth: embedded ? nil : 980, minHeight: embedded ? nil : 560)
        .onAppear {
            if statusModel.snapshots.isEmpty && !statusModel.isSnapshotsBusy {
                statusModel.fetchSnapshots()
            }
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

    @ViewBuilder
    private var restoreTitle: some View {
        if !embedded {
            Text("Restore")
                .font(.title2.weight(.semibold))
        }
    }

    private var restoreMainLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            if isSourceColumnVisible {
                restoreSourceColumn
                    .frame(width: sourceColumnWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                Divider()
            }

            restoreBrowserPanel
                .frame(minWidth: browserPanelMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isRestoreActionsPanelVisible {
                Divider()

                restoreActionsPanel
                    .frame(width: actionsPanelWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceColumnWidth: CGFloat {
        embedded ? 250 : 280
    }

    private var sourceFieldLabelWidth: CGFloat {
        64
    }

    private var browserPanelMinWidth: CGFloat {
        embedded ? 420 : 520
    }

    private var actionsPanelWidth: CGFloat {
        embedded ? 280 : 330
    }

    private var restoreToolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isSourceColumnVisible.toggle()
                }
            } label: {
                Label(isSourceColumnVisible ? "Hide Source" : "Show Source", systemImage: "sidebar.leading")
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 16)

            Label("Tree View", systemImage: "list.bullet.indent")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if statusModel.isSnapshotsBusy || statusModel.isRestoreBusy || isLoadingRestoreBrowser {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $browserFilter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restoreSourceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow(alignment: .center) {
                    Text("Snapshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: sourceFieldLabelWidth, alignment: .leading)

                    HStack(spacing: 6) {
                        Picker("Snapshot", selection: $statusModel.selectedSnapshot) {
                            Text("Latest").tag(BackupStatusModel.latestSnapshotSelection)
                            ForEach(statusModel.snapshots, id: \.id) { snapshot in
                                Text(snapshotRowLabel(snapshot)).tag(snapshot.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(statusModel.isSnapshotsBusy)

                        Button {
                            statusModel.fetchSnapshots()
                            scheduleAutomaticRestoreSearch(immediate: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Refresh snapshots")
                        .disabled(statusModel.isSnapshotsBusy)
                    }
                }

                GridRow(alignment: .center) {
                    Text("Prefix")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: sourceFieldLabelWidth, alignment: .leading)
                    TextField("Optional", text: $restorePrefix)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                GridRow(alignment: .center) {
                    Text("Contains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: sourceFieldLabelWidth, alignment: .leading)
                    TextField("Optional", text: $restoreContains)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }

            if let sourceNotice = restoreSourceNotice {
                Text(sourceNotice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private var restoreBrowserPanel: some View {
        let filteredRoots = filteredRestoreBrowserRoots
        let isFiltering = !browserFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Name")
                    .font(.headline)
                Spacer()
                if isLoadingRestoreBrowser {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(countRestoreBrowserNodes(filteredRoots)) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if filteredRoots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No matching paths")
                        .font(.headline)
                    Text("Adjust filters in Source and results will refresh automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 20)
            } else {
                RestoreBrowserTree(
                    roots: filteredRoots,
                    selectedPath: selectedBrowserPath,
                    expandedPaths: $expandedBrowserPaths,
                    loadingDirectoryKeys: restoreBrowserLoadCoordinator.loadingDirectoryKeys,
                    forceExpanded: isFiltering,
                    iconName: iconName(for:),
                    iconColor: iconColor(for:),
                    onClearSelection: clearBrowserSelection,
                    onSelect: selectBrowserPath,
                    onToggleExpansion: setBrowserNodeExpanded(path:isExpanded:),
                    onQuickLook: { path in
                        selectBrowserPath(path)
                        presentQuickLook()
                    },
                    onUseForRestore: selectBrowserPath
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var restoreActionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore")
                .font(.headline)

            if let selectedPath = activeRestorePath {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: selectedPath))
                        .foregroundStyle(iconColor(for: selectedPath))
                    VStack(alignment: .leading, spacing: 2) {
                        Text((selectedPath as NSString).lastPathComponent)
                            .lineLimit(1)
                        Text(selectedPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Destination", selection: $restoreDestinationMode) {
                    Text("Original").tag(RestoreDestinationMode.original)
                    Text("Custom").tag(RestoreDestinationMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                if restoreDestinationMode == .custom {
                    HStack(spacing: 8) {
                        TextField("Destination root", text: $restoreToDir)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("Choose...") {
                            chooseRestoreDestination()
                        }
                        .disabled(statusModel.isRestoreBusy)
                    }
                }

                Toggle("Overwrite existing files", isOn: $restoreOverwrite)
                    .disabled(restoreVerifyOnly)
                    .padding(.top, 4)
            }

            Button {
                showRestoreConfirmation = true
            } label: {
                Label(restoreVerifyOnly ? "Validate" : "Restore", systemImage: restoreVerifyOnly ? "checkmark.shield" : "arrow.down.doc.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRunRestore)
            .padding(.top, 4)

            if statusModel.isRestoreBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = restoreActionStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(restoreMessageColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            DisclosureGroup(isExpanded: $showRestoreAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Validate only (read + decrypt, no writes)", isOn: $restoreVerifyOnly)

                    TextField("Manual path override", text: $restorePath)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        statusModel.previewRestore(
                            path: restorePath,
                            toDir: effectiveRestoreToDir,
                            overwrite: restoreOverwrite,
                            snapshot: statusModel.selectedSnapshotRequestValue
                        )
                    } label: {
                        Label("Preview Target", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canRunRestore)

                    Text("Preview Target maps source to destination only. Validate only reads, decrypts, and checks integrity without writing files.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } label: {
                Text("Advanced")
                    .font(.subheadline.weight(.semibold))
            }

            if let lastRestoreAt = statusModel.lastRestoreAt {
                Text("Last restore: \(lastRestoreAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastRestorePath = statusModel.lastRestorePath {
                Text("Last path: \(lastRestorePath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
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
