import SwiftUI

extension BaxterSettingsView {
    var onboardingSection: some View {
        SettingsCard(title: "First-Run Setup", subtitle: "Start a new backup or connect one that already exists.") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(label: "Setup", error: nil) {
                    Picker("Setup Mode", selection: $onboardingMode) {
                        Text("New Backup").tag(OnboardingMode.newBackup)
                        Text("Connect Existing").tag(OnboardingMode.existingBackup)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280, alignment: .leading)
                }

                if onboardingMode == .newBackup {
                    newBackupOnboardingContent
                } else {
                    existingBackupOnboardingContent
                }

                if let onboardingError = onboardingValidationMessage {
                    SettingsAlignedContent {
                        Text(onboardingError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let onboardingMessage {
                    SettingsAlignedContent {
                        Text(onboardingMessage)
                            .font(.caption)
                            .foregroundStyle(onboardingMessageIsFailure ? Color.red : .secondary)
                    }
                }

                if statusModel.isRecoveryBusy {
                    SettingsAlignedContent {
                        ProgressView("Connecting existing backup...")
                            .controlSize(.small)
                    }
                }

                SettingsAlignedContent {
                    HStack(spacing: 8) {
                        if onboardingMode == .newBackup {
                            Button("Save Setup") {
                                completeOnboarding(runBackupNow: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.firstRunValidationMessage() != nil)

                            Button("Run First Backup Now") {
                                completeOnboarding(runBackupNow: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.firstRunValidationMessage() != nil)
                        } else {
                            Button("Connect Existing Backup") {
                                completeExistingBackupOnboarding()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(statusModel.isRecoveryBusy || onboardingValidationMessage != nil)
                        }

                        Button("Skip Wizard") {
                            onboardingDismissed = true
                        }
                        .buttonStyle(.borderless)
                        .disabled(statusModel.isRecoveryBusy)
                    }
                }
            }
        }
    }

    private var newBackupOnboardingContent: some View {
        Group {
            onboardingFolderRow

            SettingRow(label: "Schedule", error: nil) {
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

            onboardingStorageRows
            onboardingEncryptionRow
        }
    }

    private var existingBackupOnboardingContent: some View {
        Group {
            SettingRow(label: "Passphrase", error: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Required", text: $recoveryPassphrase)
                        .settingsField(width: 220)
                    Text("Baxter will save it to the configured keychain item, rebuild recovery metadata, then open Restore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingRow(label: "Keychain", error: nil) {
                Text("\(model.keychainService)/\(model.keychainAccount)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            onboardingStorageRows
        }
    }

    private var onboardingFolderRow: some View {
        SettingRow(label: "Folders", error: model.validationMessage(for: .backupRoots)) {
            VStack(alignment: .leading, spacing: 8) {
                backupRootsList

                HStack(spacing: 8) {
                    Button("Choose Folders...") {
                        model.chooseBackupRoots()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        model.clearBackupRoots()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.backupRoots.isEmpty)

                    Text("\(model.backupRoots.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var onboardingStorageRows: some View {
        Group {
            SettingRow(label: "Storage", error: nil) {
                Picker("Storage mode", selection: $onboardingStorageMode) {
                    Text("Local").tag(StorageModeOption.local)
                    Text("S3").tag(StorageModeOption.s3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220, alignment: .leading)
                .onChange(of: onboardingStorageMode) { _, mode in
                    model.setStorageMode(mode)
                }
            }

            if onboardingMode == .existingBackup && onboardingStorageMode == .local {
                SettingsAlignedContent {
                    Text("Local storage reconnects only on a Mac that still has the object store contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if onboardingStorageMode == .s3 {
                SettingRow(label: "Endpoint", error: model.validationMessage(for: .s3Endpoint)) {
                    TextField("Optional, for example https://s3.amazonaws.com", text: $model.s3Endpoint)
                        .settingsField(width: 420)
                        .onChange(of: model.s3Endpoint) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Region", error: model.validationMessage(for: .s3Region)) {
                    TextField("us-west-2", text: $model.s3Region)
                        .settingsField(width: 180)
                        .onChange(of: model.s3Region) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Bucket", error: model.validationMessage(for: .s3Bucket)) {
                    TextField("my-backups", text: $model.s3Bucket)
                        .settingsField(width: 240)
                        .onChange(of: model.s3Bucket) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Prefix", error: model.validationMessage(for: .s3Prefix)) {
                    TextField("baxter/", text: $model.s3Prefix)
                        .settingsField(width: 180)
                        .onChange(of: model.s3Prefix) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "AWS Profile", error: model.validationMessage(for: .s3AWSProfile)) {
                    TextField("Optional, for example baxter", text: $model.s3AWSProfile)
                        .settingsField(width: 220, monospaced: true)
                        .onChange(of: model.s3AWSProfile) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingsAlignedContent {
                    Text(model.s3ModeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var onboardingEncryptionRow: some View {
        SettingRow(label: "Encryption", error: nil) {
            Text(model.hasConfiguredKeySource ? "Using the configured keychain item or BAXTER_PASSPHRASE." : "Set BAXTER_PASSPHRASE or the keychain service/account before the first backup runs.")
                .font(.callout)
                .foregroundStyle(model.hasConfiguredKeySource ? Color.secondary : .red)
        }
    }

    private var onboardingValidationMessage: String? {
        if onboardingMode == .newBackup {
            return model.firstRunValidationMessage()
        }
        return model.existingBackupValidationMessage(passphrase: recoveryPassphrase)
    }

    private var onboardingMessageIsFailure: Bool {
        guard let onboardingMessage else {
            return false
        }
        let normalized = onboardingMessage.lowercased()
        return normalized.contains("failed")
            || normalized.contains("error")
            || normalized.contains("did not reconnect in time")
    }
}
