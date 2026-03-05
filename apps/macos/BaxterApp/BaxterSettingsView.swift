import SwiftUI

struct BaxterSettingsView: View {
    @ObservedObject var model: BaxterSettingsModel
    @ObservedObject var statusModel: BackupStatusModel
    var embedded: Bool = false
    @AppStorage("baxter.onboarding.dismissed") private var onboardingDismissed = false
    @State private var showApplyNow = false
    @State private var onboardingStorageMode: StorageModeOption = .local
    @State private var onboardingMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                Text("Baxter Settings")
                    .font(.title2.weight(.semibold))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShowOnboarding {
                        SettingsCard(title: "First-Run Setup", subtitle: "Guided setup for your first successful backup.") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Backup folders")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(model.backupRoots.count) selected")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Button("Choose Folders...") {
                                        model.chooseBackupRoots()
                                    }
                                    Button("Clear") {
                                        model.clearBackupRoots()
                                    }
                                    .disabled(model.backupRoots.isEmpty)
                                }

                                HStack(alignment: .center, spacing: 12) {
                                    Text("Schedule")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 110, alignment: .leading)
                                    Picker("Schedule", selection: $model.schedule) {
                                        ForEach(BackupSchedule.allCases) { schedule in
                                            Text(schedule.rawValue.capitalized).tag(schedule)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 170, alignment: .leading)
                                    .onChange(of: model.schedule) { _, _ in
                                        model.validateDraft()
                                    }
                                }

                                HStack(alignment: .center, spacing: 12) {
                                    Text("Storage mode")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 110, alignment: .leading)
                                    Picker("Storage mode", selection: $onboardingStorageMode) {
                                        Text("Local").tag(StorageModeOption.local)
                                        Text("S3").tag(StorageModeOption.s3)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 220)
                                    .onChange(of: onboardingStorageMode) { _, mode in
                                        model.setStorageMode(mode)
                                    }
                                    Spacer()
                                }

                                if onboardingStorageMode == .s3 {
                                    SettingRow(label: "S3 Region", error: model.validationMessage(for: .s3Region)) {
                                        TextField("us-west-2", text: $model.s3Region)
                                            .onChange(of: model.s3Region) { _, _ in
                                                model.validateDraft()
                                            }
                                    }
                                    SettingRow(label: "S3 Bucket", error: model.validationMessage(for: .s3Bucket)) {
                                        TextField("my-backups", text: $model.s3Bucket)
                                            .onChange(of: model.s3Bucket) { _, _ in
                                                model.validateDraft()
                                            }
                                    }
                                }

                                if model.hasConfiguredKeySource {
                                    Text("Encryption key source: configured")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Encryption key source: configure BAXTER_PASSPHRASE or keychain service/account.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                if let onboardingError = model.firstRunValidationMessage() {
                                    Text(onboardingError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if let onboardingMessage {
                                    Text(onboardingMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 8) {
                                    Button("Save Setup") {
                                        completeOnboarding(runBackupNow: false)
                                    }
                                    .disabled(model.firstRunValidationMessage() != nil)

                                    Button("Run First Backup Now") {
                                        completeOnboarding(runBackupNow: true)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.firstRunValidationMessage() != nil)

                                    Button("Skip Wizard") {
                                        onboardingDismissed = true
                                    }
                                }
                            }
                        }
                    }

                    SettingsCard(title: "Backup", subtitle: "Choose folders to include in backups.") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.backupRoots.isEmpty {
                                Text("No folders selected.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                ForEach(model.backupRoots, id: \.self) { root in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "folder")
                                                .foregroundStyle(.secondary)
                                            Text(root)
                                                .font(.system(.body, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Button {
                                                model.removeBackupRoot(root)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        if let warning = model.backupRootWarning(for: root) {
                                            Text(warning)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }

                            HStack(spacing: 10) {
                                Button("Add Folder...") {
                                    model.chooseBackupRoots()
                                }
                                Button("Remove All") {
                                    model.clearBackupRoots()
                                }
                                .disabled(model.backupRoots.isEmpty)
                            }
                            if let error = model.validationMessage(for: .backupRoots) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Exclude Paths (absolute, one per line)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextEditor(text: $model.excludePathsText)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 68, maxHeight: 88)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                    .onChange(of: model.excludePathsText) { _, _ in
                                        model.validateDraft()
                                    }
                                if let error = model.validationMessage(for: .excludePaths) {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Exclude Globs (one per line)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextEditor(text: $model.excludeGlobsText)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 68, maxHeight: 88)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                    .onChange(of: model.excludeGlobsText) { _, _ in
                                        model.validateDraft()
                                    }
                                if let error = model.validationMessage(for: .excludeGlobs) {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }

                            HStack(alignment: .center, spacing: 12) {
                                Text("Backup Schedule")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("Backup Schedule", selection: $model.schedule) {
                                    ForEach(BackupSchedule.allCases) { schedule in
                                        Text(schedule.rawValue.capitalized).tag(schedule)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150, alignment: .leading)
                                .onChange(of: model.schedule) { _, _ in
                                    model.validateDraft()
                                }
                                Spacer()
                            }

                            if model.schedule == .daily {
                                SettingRow(label: "Daily Time", error: model.validationMessage(for: .dailyTime)) {
                                    TextField("HH:MM", text: $model.dailyTime)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 90, alignment: .leading)
                                        .onChange(of: model.dailyTime) { _, _ in
                                            model.validateDraft()
                                        }
                                }
                            }

                            if model.schedule == .weekly {
                                SettingRow(label: "Weekly Day", error: model.validationMessage(for: .weeklyDay)) {
                                    Picker("Weekly Day", selection: $model.weeklyDay) {
                                        ForEach(WeekdayOption.allCases) { day in
                                            Text(day.rawValue.capitalized).tag(day)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140, alignment: .leading)
                                    .onChange(of: model.weeklyDay) { _, _ in
                                        model.validateDraft()
                                    }
                                }
                                SettingRow(label: "Weekly Time", error: model.validationMessage(for: .weeklyTime)) {
                                    TextField("HH:MM", text: $model.weeklyTime)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 90, alignment: .leading)
                                        .onChange(of: model.weeklyTime) { _, _ in
                                            model.validateDraft()
                                        }
                                }
                            }
                        }
                    }

                    SettingsCard(title: "Verify", subtitle: "Schedule and scope integrity verification runs.") {
                        VStack(spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Verify Schedule")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("Verify Schedule", selection: $model.verifySchedule) {
                                    ForEach(BackupSchedule.allCases) { schedule in
                                        Text(schedule.rawValue.capitalized).tag(schedule)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150, alignment: .leading)
                                .onChange(of: model.verifySchedule) { _, _ in
                                    model.validateDraft()
                                }
                                Spacer()
                            }

                            if model.verifySchedule == .daily {
                                SettingRow(label: "Daily Time", error: model.validationMessage(for: .verifyDailyTime)) {
                                    TextField("HH:MM", text: $model.verifyDailyTime)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 90, alignment: .leading)
                                        .onChange(of: model.verifyDailyTime) { _, _ in
                                            model.validateDraft()
                                        }
                                }
                            }

                            if model.verifySchedule == .weekly {
                                SettingRow(label: "Weekly Day", error: model.validationMessage(for: .verifyWeeklyDay)) {
                                    Picker("Weekly Day", selection: $model.verifyWeeklyDay) {
                                        ForEach(WeekdayOption.allCases) { day in
                                            Text(day.rawValue.capitalized).tag(day)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140, alignment: .leading)
                                    .onChange(of: model.verifyWeeklyDay) { _, _ in
                                        model.validateDraft()
                                    }
                                }
                                SettingRow(label: "Weekly Time", error: model.validationMessage(for: .verifyWeeklyTime)) {
                                    TextField("HH:MM", text: $model.verifyWeeklyTime)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 90, alignment: .leading)
                                        .onChange(of: model.verifyWeeklyTime) { _, _ in
                                            model.validateDraft()
                                        }
                                }
                            }

                            SettingRow(label: "Prefix", error: nil) {
                                TextField("/Users/you/Documents (optional)", text: $model.verifyPrefix)
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: model.verifyPrefix) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Limit", error: model.validationMessage(for: .verifyLimit)) {
                                TextField("0", text: $model.verifyLimit)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 100, alignment: .leading)
                                    .onChange(of: model.verifyLimit) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Sample", error: model.validationMessage(for: .verifySample)) {
                                TextField("0", text: $model.verifySample)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 100, alignment: .leading)
                                    .onChange(of: model.verifySample) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                        }
                    }

                    SettingsCard(title: "S3", subtitle: "Leave bucket empty for local object storage.") {
                        VStack(spacing: 8) {
                            SettingRow(label: "Endpoint", error: model.validationMessage(for: .s3Endpoint)) {
                                TextField("https://s3.amazonaws.com (optional)", text: $model.s3Endpoint)
                                    .onChange(of: model.s3Endpoint) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Region", error: model.validationMessage(for: .s3Region)) {
                                TextField("us-west-2", text: $model.s3Region)
                                    .onChange(of: model.s3Region) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Bucket", error: model.validationMessage(for: .s3Bucket)) {
                                TextField("my-backups", text: $model.s3Bucket)
                                    .onChange(of: model.s3Bucket) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Prefix", error: model.validationMessage(for: .s3Prefix)) {
                                TextField("baxter/", text: $model.s3Prefix)
                                    .onChange(of: model.s3Prefix) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            Text(model.s3ModeHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    SettingsCard(title: "Encryption", subtitle: "Keychain item used when BAXTER_PASSPHRASE is not set.") {
                        VStack(spacing: 8) {
                            SettingRow(label: "Service", error: model.validationMessage(for: .keychainService)) {
                                TextField("baxter", text: $model.keychainService)
                                    .onChange(of: model.keychainService) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                            SettingRow(label: "Account", error: model.validationMessage(for: .keychainAccount)) {
                                TextField("default", text: $model.keychainAccount)
                                    .onChange(of: model.keychainAccount) { _, _ in
                                        model.validateDraft()
                                    }
                            }
                        }
                    }

                    SettingsCard(title: "Notifications", subtitle: "Failure alerts are always enabled; success alerts are optional.") {
                        Toggle("Notify on successful backup/verify", isOn: $statusModel.notifyOnSuccess)
                            .toggleStyle(.switch)
                    }

                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("Config: \(model.configURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let statusMessage = model.statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Reload") {
                    model.load()
                    showApplyNow = false
                }
                Button("Save") {
                    model.save()
                    showApplyNow = model.shouldOfferApplyNow(daemonState: statusModel.daemonServiceState)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .keyboardShortcut("s", modifiers: [.command])
            }
            if showApplyNow {
                HStack(spacing: 10) {
                    Text("Saved settings. Restart daemon to apply changes now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply Now") {
                        statusModel.applyConfigNow()
                        showApplyNow = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(statusModel.isLifecycleBusy)
                }
            }
        }
        .padding(embedded ? 12 : 16)
        .frame(minWidth: embedded ? nil : 700, minHeight: embedded ? nil : 620)
        .onChange(of: statusModel.daemonServiceState) { _, state in
            if state != .running {
                showApplyNow = false
            }
        }
        .onAppear {
            onboardingStorageMode = model.storageMode()
        }
    }

    private var shouldShowOnboarding: Bool {
        !onboardingDismissed && (!model.configExists || model.backupRoots.isEmpty)
    }

    private func completeOnboarding(runBackupNow: Bool) {
        if let validation = model.firstRunValidationMessage() {
            onboardingMessage = validation
            return
        }

        model.save()
        if let error = model.errorMessage {
            onboardingMessage = error
            return
        }

        onboardingDismissed = true
        if !runBackupNow {
            onboardingMessage = "Setup saved. You can run backup now from the menu bar."
            return
        }

        if statusModel.daemonServiceState != .running {
            statusModel.startDaemon()
            onboardingMessage = "Setup saved. Daemon starting; run first backup once daemon is running."
            return
        }

        statusModel.runBackup()
        onboardingMessage = "Setup saved. First backup started."
    }
}

struct BaxterRestoreView: View {
    private enum RestoreDestinationMode: String {
        case original
        case custom
    }

    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    var embedded: Bool = false
    private let restoreRootDirectoryKey = "__root__"
    private let restorePlaceholderPrefix = "__restore_placeholder__:"
    @State private var restorePrefix = ""
    @State private var restoreContains = ""
    @State private var restorePath = ""
    @State private var restoreToDir = ""
    @State private var restoreOverwrite = false
    @State private var restoreVerifyOnly = false
    @State private var showRestoreAdvanced = false
    @State private var restoreDestinationMode: RestoreDestinationMode = .original
    @State private var isSourceColumnVisible = false
    @State private var hasAutoLoadedRestore = false
    @State private var restoreSearchDebounceTask: Task<Void, Never>?
    @State private var browserFilter = ""
    @State private var selectedBrowserPath: String?
    @State private var restoreBrowserRoots: [RestoreBrowserNode] = []
    @State private var restorePathKinds: [String: Bool] = [:]
    @State private var loadedRestorePaths: Set<String> = []
    @State private var loadedRestoreDirectoryPaths: Set<String> = []
    @State private var loadingRestoreDirectoryPaths: Set<String> = []
    @State private var restoreRootPrefix = ""
    @State private var isIndexingRestorePaths = false
    @State private var showRestoreConfirmation = false
    @State private var showQuickLook = false

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
        let visibleRoots = decorateRestoreNodesForLazyExpansion(filteredRoots)

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

            if visibleRoots.isEmpty {
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
                List {
                    OutlineGroup(visibleRoots, children: \.childNodes) { node in
                        if node.isPlaceholder {
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .onAppear {
                                    loadRestoreChildrenFromPlaceholder(node.path)
                                }
                        } else {
                            let isSelected = selectedBrowserPath == node.path
                            HStack(spacing: 6) {
                                Label(node.name, systemImage: iconName(for: node.path))
                                    .lineLimit(1)
                                if loadingRestoreDirectoryPaths.contains(node.path) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectBrowserPath(node.path)
                            }
                            .listRowBackground(
                                isSelected
                                    ? Color.accentColor.opacity(0.24)
                                    : Color.clear
                            )
                            .contextMenu {
                                Button("Quick Look") {
                                    selectBrowserPath(node.path)
                                    presentQuickLook()
                                }
                                Button("Use for Restore") {
                                    selectBrowserPath(node.path)
                                }
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
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
                        .foregroundStyle(.secondary)
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

    private var activeRestorePath: String? {
        if let selectedBrowserPath, !selectedBrowserPath.isEmpty {
            return selectedBrowserPath
        }
        let manualPath = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return manualPath.isEmpty ? nil : manualPath
    }

    @ViewBuilder
    private var quickLookSheet: some View {
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

    private var filteredRestoreBrowserRoots: [RestoreBrowserNode] {
        filterRestoreBrowserNodes(scopedRestoreBrowserRoots, query: browserFilter)
    }

    private var isLoadingRestoreBrowser: Bool {
        !loadingRestoreDirectoryPaths.isEmpty
    }

    private var filteredRestoreBrowserPaths: [String] {
        flattenRestoreBrowserNodePaths(filteredRestoreBrowserRoots)
    }

    private var isRestoreActionsPanelVisible: Bool {
        activeRestorePath != nil
    }

    private var scopedRestoreBrowserRoots: [RestoreBrowserNode] {
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

    private var restoreMessageColor: Color {
        let message = restoreActionStatusMessage?.lowercased() ?? ""
        if message.contains("failed") || message.contains("error") {
            return .red
        }
        return .secondary
    }

    private var effectiveRestoreToDir: String {
        guard restoreDestinationMode == .custom else {
            return ""
        }
        return restoreToDir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRunRestore: Bool {
        let source = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statusModel.isRestoreBusy, !source.isEmpty else {
            return false
        }
        if restoreDestinationMode == .custom {
            return !effectiveRestoreToDir.isEmpty
        }
        return true
    }

    private var restoreActionStatusMessage: String? {
        guard let message = statusModel.restorePreviewMessage, !message.isEmpty else {
            return nil
        }
        return isBrowserStatusMessage(message) ? nil : message
    }

    private var restoreBrowserStatusMessage: String? {
        guard let message = statusModel.restorePreviewMessage, !message.isEmpty else {
            return nil
        }
        return isBrowserStatusMessage(message) ? message : nil
    }

    private var restoreSourceNotice: String? {
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

    private func isBrowserStatusMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.hasPrefix("loaded ") || lowered.hasPrefix("found ") || lowered.hasPrefix("restore list")
    }

    private func presentQuickLook() {
        if selectedBrowserPath == nil, let firstPath = filteredRestoreBrowserPaths.first {
            selectBrowserPath(firstPath)
        }
        guard activeRestorePath != nil else {
            return
        }
        showQuickLook = true
    }

    private func selectBrowserPath(_ path: String) {
        if isRestorePlaceholderPath(path) {
            return
        }
        selectedBrowserPath = path
        restorePath = path
        if restorePathKinds[path] == true {
            loadRestoreChildren(parentPath: path)
        }
    }

    private func searchRestorePaths() {
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

    private func triggerInitialRestoreLoadIfNeeded() {
        guard !hasAutoLoadedRestore else {
            return
        }
        hasAutoLoadedRestore = true
        scheduleAutomaticRestoreSearch(immediate: true)
    }

    private func scheduleAutomaticRestoreSearch(immediate: Bool = false) {
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

    private func iconName(for path: String) -> String {
        restorePathKinds[path] == true ? "folder" : "doc"
    }

    private func indexRestorePaths(_ restorePaths: [String]) {
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

    private func loadRestoreChildren(parentPath: String?) {
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

    private func mergeRestorePaths(_ paths: [String]) {
        for path in paths {
            loadedRestorePaths.insert(path)
        }
        indexRestorePaths(Array(loadedRestorePaths))
    }

    private func decorateRestoreNodesForLazyExpansion(_ nodes: [RestoreBrowserNode]) -> [RestoreBrowserNode] {
        nodes.map(decorateRestoreNodeForLazyExpansion(_:))
    }

    private func decorateRestoreNodeForLazyExpansion(_ node: RestoreBrowserNode) -> RestoreBrowserNode {
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

    private func makeRestorePlaceholderNode(parentPath: String) -> RestoreBrowserNode {
        RestoreBrowserNode(
            path: "\(restorePlaceholderPrefix)\(parentPath)",
            name: "Loading...",
            isDirectory: false,
            children: [],
            isPlaceholder: true
        )
    }

    private func isRestorePlaceholderPath(_ path: String) -> Bool {
        path.hasPrefix(restorePlaceholderPrefix)
    }

    private func restoreParentPathForPlaceholder(_ path: String) -> String? {
        guard isRestorePlaceholderPath(path) else {
            return nil
        }
        let parentPath = String(path.dropFirst(restorePlaceholderPrefix.count))
        return parentPath.isEmpty ? nil : parentPath
    }

    private func loadRestoreChildrenFromPlaceholder(_ path: String) {
        guard let parentPath = restoreParentPathForPlaceholder(path) else {
            return
        }
        loadRestoreChildren(parentPath: parentPath)
    }

    private func normalizedRestorePrefix(_ rawPrefix: String) -> String {
        var value = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "/" {
            return value
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func resolvedRestoreRootPrefix() -> String {
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

    private func findRestoreBrowserNode(path: String, nodes: [RestoreBrowserNode]) -> RestoreBrowserNode? {
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

    private func chooseRestoreDestination() {
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

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                content
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
