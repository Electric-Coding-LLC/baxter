import SwiftUI

extension BaxterSettingsView {
    var onboardingPane: some View {
        Form {
            Section {
                Picker("Setup", selection: $onboardingMode) {
                    Text("New Backup").tag(OnboardingMode.newBackup)
                    Text("Connect Existing").tag(OnboardingMode.existingBackup)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Set Up Baxter")
            } footer: {
                Text("Start a new backup or connect one that already exists.")
            }

            if onboardingMode == .newBackup {
                newBackupOnboardingSections
            } else {
                existingBackupOnboardingSections
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            onboardingFooter
        }
    }

    private var onboardingFooter: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if statusModel.isRecoveryBusy {
                    ProgressView("Connecting existing backup…")
                        .controlSize(.small)
                } else if let onboardingMessage {
                    Text(onboardingMessage)
                        .font(.callout)
                        .foregroundStyle(onboardingMessageIsFailure ? Color.red : .secondary)
                } else if let onboardingValidationMessage {
                    Text(onboardingValidationMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Skip Setup") {
                        onboardingDismissed = true
                    }
                    .disabled(statusModel.isRecoveryBusy)

                    Spacer(minLength: 12)

                    if onboardingMode == .newBackup {
                        Button("Save Setup") {
                            completeOnboarding(runBackupNow: false)
                        }
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
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var newBackupOnboardingSections: some View {
        backupRootsSection(footer: "Choose the folders Baxter should back up.")

        Section("Schedule") {
            schedulePicker("Run Backups", selection: $model.schedule)
        }

        onboardingStorageSection

        Section("Encryption") {
            Text(model.hasConfiguredKeySource ? "Using the configured keychain item or BAXTER_PASSPHRASE." : "Set BAXTER_PASSPHRASE or the keychain service/account before the first backup runs.")
                .foregroundStyle(model.hasConfiguredKeySource ? Color.secondary : .red)
        }
    }

    @ViewBuilder
    private var existingBackupOnboardingSections: some View {
        Section {
            SecureField("Passphrase", text: $recoveryPassphrase, prompt: Text("Required"))
            LabeledContent("Keychain Item") {
                Text("\(model.keychainService)/\(model.keychainAccount)")
                    .font(.callout.monospaced())
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Baxter will save it to the configured keychain item, rebuild recovery metadata, then open Restore.")
        }

        onboardingStorageSection
    }

    private var onboardingStorageSection: some View {
        Section {
            Picker("Store Backups", selection: $onboardingStorageMode) {
                Text("On This Mac").tag(StorageModeOption.local)
                Text("In S3").tag(StorageModeOption.s3)
            }
            .pickerStyle(.segmented)
            .onChange(of: onboardingStorageMode) { _, mode in
                model.setStorageMode(mode)
            }

            if onboardingStorageMode == .s3 {
                s3Fields
            }
        } header: {
            Text("Storage")
        } footer: {
            if onboardingStorageMode == .s3 {
                Text(model.s3ModeHint)
            } else if onboardingMode == .existingBackup {
                Text("Local storage reconnects only on a Mac that still has the object store contents.")
            }
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
