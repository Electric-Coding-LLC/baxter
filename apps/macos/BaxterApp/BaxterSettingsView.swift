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
    @ObservedObject var statusModel: BackupStatusModel
    var embedded: Bool = false
    private let maxVisibleResults = 2000
    @State private var restorePrefix = ""
    @State private var restoreContains = ""
    @State private var restorePath = ""
    @State private var restoreToDir = ""
    @State private var restoreOverwrite = false
    @State private var restoreVerifyOnly = false
    @State private var browserFilter = ""
    @State private var selectedBrowserPath: String?
    @State private var sortedRestorePaths: [String] = []
    @State private var directoryPathCache: Set<String> = []
    @State private var isIndexingRestorePaths = false
    @State private var showRestoreConfirmation = false
    @State private var showQuickLook = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            restoreTitle
            restoreToolbar
            restoreMainLayout
        }
        .padding(embedded ? 2 : 8)
        .frame(minWidth: embedded ? nil : 980, minHeight: embedded ? nil : 560)
        .onAppear {
            if statusModel.snapshots.isEmpty && !statusModel.isSnapshotsBusy {
                statusModel.fetchSnapshots()
            }
        }
        .onChange(of: statusModel.selectedSnapshot) { _, _ in
            selectedBrowserPath = nil
            restorePath = ""
            sortedRestorePaths = []
            directoryPathCache = []
            statusModel.restorePaths = []
            statusModel.restorePreviewMessage = "Pick filters, then click Load Files."
        }
        .onChange(of: selectedBrowserPath) { _, selectedPath in
            if let selectedPath {
                restorePath = selectedPath
            }
        }
        .onChange(of: statusModel.restorePaths) { _, restorePaths in
            indexRestorePaths(restorePaths)
        }
        .onMoveCommand { direction in
            handleMoveCommand(direction, visiblePaths: filteredRestorePaths)
        }
        .alert("Confirm Restore", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Run Restore", role: .destructive) {
                statusModel.runRestore(
                    path: restorePath,
                    toDir: restoreToDir,
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

    private var snapshotSummary: some View {
        Group {
            if let selectedSnapshot = statusModel.selectedSnapshotSummary {
                Text("Selected snapshot: \(selectedSnapshot.createdAt) • \(selectedSnapshot.entries) files")
                    .textSelection(.enabled)
            } else {
                Text("Selected snapshot: latest")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var snapshotsStatus: some View {
        if let snapshotsMessage = statusModel.snapshotsMessage {
            Text(snapshotsMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var restoreMainLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            restoreSourceColumn
                .frame(width: sourceColumnWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider()

            restoreBrowserPanel
                .frame(minWidth: browserPanelMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            restoreActionsPanel
                .frame(width: actionsPanelWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceColumnWidth: CGFloat {
        embedded ? 250 : 280
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
                // Finder-like nav affordance placeholder.
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(true)

            Button {
                // Finder-like nav affordance placeholder.
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(true)

            Divider()
                .frame(height: 16)

            Label("Column View", systemImage: "rectangle.split.3x1")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if statusModel.isSnapshotsBusy || statusModel.isRestoreBusy || isIndexingRestorePaths {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                presentQuickLook()
            } label: {
                Image(systemName: "space")
            }
            .buttonStyle(.borderless)
            .help("Quick Look (Space)")
            .disabled(activeRestorePath == nil)
            .keyboardShortcut(.space, modifiers: [])

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
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var restoreSourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source")
                .font(.headline)

            HStack(spacing: 8) {
                Text("Snapshot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Snapshot", selection: $statusModel.selectedSnapshot) {
                    Text("Latest").tag(BackupStatusModel.latestSnapshotSelection)
                    ForEach(statusModel.snapshots, id: \.id) { snapshot in
                        Text(snapshotRowLabel(snapshot)).tag(snapshot.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(statusModel.isSnapshotsBusy)
            }

            Button {
                statusModel.fetchSnapshots()
            } label: {
                Label("Refresh Snapshots", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(statusModel.isSnapshotsBusy)

            TextField("Prefix filter (optional)", text: $restorePrefix)
                .textFieldStyle(.roundedBorder)
            TextField("Contains text (optional)", text: $restoreContains)
                .textFieldStyle(.roundedBorder)

            Button {
                searchRestorePaths()
            } label: {
                Label("Load Files", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(statusModel.isRestoreBusy)

            Divider()

            snapshotSummary
            snapshotsStatus

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var restoreBrowserPanel: some View {
        let visiblePaths = filteredRestorePaths

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name")
                    .font(.headline)
                Spacer()
                if isIndexingRestorePaths {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(visiblePaths.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if visiblePaths.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No matching paths")
                        .font(.headline)
                    Text("Adjust filters and click Load Files to fetch backup paths.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 20)
            } else {
                List(selection: $selectedBrowserPath) {
                    ForEach(visiblePaths, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(pathName(for: path), systemImage: iconName(for: path))
                                .lineLimit(1)
                            Text(parentPath(for: path))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .tag(path)
                        .contextMenu {
                            Button("Quick Look") {
                                selectedBrowserPath = path
                                presentQuickLook()
                            }
                            Button("Use for Restore") {
                                selectedBrowserPath = path
                                restorePath = path
                            }
                        }
                    }
                }
                .listStyle(.plain)

                if hasMoreResults {
                    Text("Showing first \(maxVisibleResults) matches. Narrow filters for more precise results.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.trailing, 10)
    }

    private var restoreActionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore")
                .font(.headline)

            Text("Set destination and run dry-run or restore.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Path to restore", text: $restorePath)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            if let selectedPath = activeRestorePath {
                Text(selectedPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                TextField("Destination root (optional)", text: $restoreToDir)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseRestoreDestination()
                }
                .disabled(statusModel.isRestoreBusy)
            }

            Toggle("Overwrite existing files", isOn: $restoreOverwrite)
            Toggle("Verify only (no writes)", isOn: $restoreVerifyOnly)

            Button {
                statusModel.previewRestore(
                    path: restorePath,
                    toDir: restoreToDir,
                    overwrite: restoreOverwrite,
                    snapshot: statusModel.selectedSnapshotRequestValue
                )
            } label: {
                Label("Dry Run", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(statusModel.isRestoreBusy || restorePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                showRestoreConfirmation = true
            } label: {
                Label("Run Restore", systemImage: "arrow.down.doc.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(statusModel.isRestoreBusy || restorePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if statusModel.isRestoreBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = statusModel.restorePreviewMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(restoreMessageColor)
                    .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

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
            if let lastRestoreError = statusModel.lastRestoreError, !lastRestoreError.isEmpty {
                Text("Last error: \(lastRestoreError)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 14)
        .padding(.vertical, 6)
    }

    private func snapshotRowLabel(_ snapshot: SnapshotSummary) -> String {
        let id = snapshot.id.count > 14 ? "\(snapshot.id.prefix(14))…" : snapshot.id
        return "\(id) (\(snapshot.entries))"
    }

    private var restoreConfirmationSummary: String {
        let source = restorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = restoreToDir.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        Text(pathName(for: previewPath))
                            .font(.title3.weight(.semibold))
                        Text(parentPath(for: previewPath))
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

    private var filteredRestorePaths: [String] {
        let query = browserFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sortedRestorePaths
        guard !query.isEmpty else {
            return Array(source.prefix(maxVisibleResults))
        }
        return Array(source.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(maxVisibleResults))
    }

    private var hasMoreResults: Bool {
        sortedRestorePaths.count > maxVisibleResults
    }

    private var restoreMessageColor: Color {
        let message = statusModel.restorePreviewMessage?.lowercased() ?? ""
        if message.contains("failed") || message.contains("error") {
            return .red
        }
        return .secondary
    }

    private func presentQuickLook() {
        if selectedBrowserPath == nil {
            selectedBrowserPath = filteredRestorePaths.first
        }
        guard activeRestorePath != nil else {
            return
        }
        showQuickLook = true
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection, visiblePaths: [String]) {
        guard !visiblePaths.isEmpty else {
            return
        }
        guard direction == .up || direction == .down else {
            return
        }

        guard let selected = selectedBrowserPath, let currentIndex = visiblePaths.firstIndex(of: selected) else {
            selectedBrowserPath = visiblePaths.first
            return
        }

        let delta = direction == .down ? 1 : -1
        let nextIndex = max(0, min(visiblePaths.count - 1, currentIndex + delta))
        selectedBrowserPath = visiblePaths[nextIndex]
    }

    private func searchRestorePaths() {
        selectedBrowserPath = nil
        restorePath = ""
        sortedRestorePaths = []
        directoryPathCache = []
        isIndexingRestorePaths = true
        statusModel.fetchRestoreList(
            prefix: restorePrefix,
            contains: restoreContains,
            snapshot: statusModel.selectedSnapshotRequestValue
        )
    }

    private func pathName(for path: String) -> String {
        let lastPath = URL(fileURLWithPath: path).lastPathComponent
        return lastPath.isEmpty ? path : lastPath
    }

    private func parentPath(for path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func iconName(for path: String) -> String {
        directoryPathCache.contains(path) ? "folder" : "doc"
    }

    private func indexRestorePaths(_ restorePaths: [String]) {
        if restorePaths.isEmpty {
            sortedRestorePaths = []
            directoryPathCache = []
            isIndexingRestorePaths = false
            return
        }

        Task.detached(priority: .userInitiated) {
            let sorted = restorePaths.sorted()
            let directories = buildDirectoryPaths(restorePaths: restorePaths)
            await MainActor.run {
                self.sortedRestorePaths = sorted
                self.directoryPathCache = directories
                self.isIndexingRestorePaths = false
            }
        }
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
        restoreToDir = selectedURL.path
    }
}

private func buildDirectoryPaths(restorePaths: [String]) -> Set<String> {
    var folders: Set<String> = []
    for path in restorePaths {
        let isAbsolute = path.hasPrefix("/")
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            continue
        }
        var currentPath = ""
        for component in components.dropLast() {
            if isAbsolute {
                currentPath += "/\(component)"
            } else if currentPath.isEmpty {
                currentPath = component
            } else {
                currentPath += "/\(component)"
            }
            folders.insert(currentPath)
        }
    }
    return folders
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
