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
                            SettingRow(label: "AWS Profile", error: model.validationMessage(for: .s3AWSProfile)) {
                                TextField("baxter (optional)", text: $model.s3AWSProfile)
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: model.s3AWSProfile) { _, _ in
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
