import SwiftUI

extension BaxterSettingsView {
    var onboardingSection: some View {
        SettingsCard(title: "First-Run Setup", subtitle: "Start a new backup or connect one that already exists.") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(label: "Setup Mode", error: nil) {
                    Picker("Setup Mode", selection: $onboardingMode) {
                        Text("New Backup").tag(OnboardingMode.newBackup)
                        Text("Connect Existing").tag(OnboardingMode.existingBackup)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                if onboardingMode == .newBackup {
                    newBackupOnboardingContent
                } else {
                    existingBackupOnboardingContent
                }

                onboardingStorageSection

                if let onboardingError = onboardingValidationMessage {
                    Text(onboardingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let onboardingMessage {
                    Text(onboardingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if statusModel.isRecoveryBusy {
                    ProgressView("Connecting existing backup...")
                        .controlSize(.small)
                }

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

    private var newBackupOnboardingContent: some View {
        Group {
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
                .buttonStyle(.bordered)

                Button("Clear") {
                    model.clearBackupRoots()
                }
                .buttonStyle(.bordered)
                .disabled(model.backupRoots.isEmpty)
            }

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

            encryptionSourceHint
        }
    }

    private var existingBackupOnboardingContent: some View {
        Group {
            Text("Enter the storage details for the existing backup set. Baxter will save the passphrase into the configured macOS keychain item, bootstrap recovery metadata, then open Restore.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingRow(label: "Passphrase", error: nil) {
                SecureField("Required", text: $recoveryPassphrase)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Keychain destination: \(model.keychainService)/\(model.keychainAccount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if onboardingStorageMode == .local {
                Text("Local storage only reconnects on a machine that still has the object store contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var onboardingStorageSection: some View {
        Group {
            SettingRow(label: "Storage Mode", error: nil) {
                Picker("Storage mode", selection: $onboardingStorageMode) {
                    Text("Local").tag(StorageModeOption.local)
                    Text("S3").tag(StorageModeOption.s3)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: onboardingStorageMode) { _, mode in
                    model.setStorageMode(mode)
                }
            }

            if onboardingStorageMode == .s3 {
                SettingRow(label: "S3 Region", error: model.validationMessage(for: .s3Region)) {
                    TextField("us-west-2", text: $model.s3Region)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Region) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "S3 Bucket", error: model.validationMessage(for: .s3Bucket)) {
                    TextField("my-backups", text: $model.s3Bucket)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Bucket) { _, _ in
                            model.validateDraft()
                        }
                }
            }
        }
    }

    private var encryptionSourceHint: some View {
        Group {
            if model.hasConfiguredKeySource {
                Text("Encryption key source: configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Encryption key source: configure BAXTER_PASSPHRASE or keychain service/account.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var onboardingValidationMessage: String? {
        if onboardingMode == .newBackup {
            return model.firstRunValidationMessage()
        }
        return model.existingBackupValidationMessage(passphrase: recoveryPassphrase)
    }
}
