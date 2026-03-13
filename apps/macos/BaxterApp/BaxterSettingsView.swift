import SwiftUI

struct BaxterSettingsView: View {
    enum OnboardingMode: String, CaseIterable, Identifiable {
        case newBackup
        case existingBackup

        var id: String { rawValue }
    }

    @ObservedObject var model: BaxterSettingsModel
    @ObservedObject var statusModel: BackupStatusModel
    var onRecoveryConnected: (() -> Void)? = nil
    var embedded: Bool = false
    @AppStorage("baxter.onboarding.dismissed") var onboardingDismissed = false
    @State var showApplyNow = false
    @State var onboardingMode: OnboardingMode = .newBackup
    @State var onboardingStorageMode: StorageModeOption = .local
    @State var recoveryPassphrase = ""
    @State var onboardingMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shouldShowOnboarding {
                        onboardingSection
                        sectionDivider
                    }

                    backupSection
                    sectionDivider
                    verifySection
                    sectionDivider
                    s3Section
                    sectionDivider
                    encryptionSection
                    sectionDivider
                    notificationsSection
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: .infinity)

            Divider()
            settingsFooter
        }
        .padding(embedded ? 0 : 10)
        .frame(minWidth: embedded ? nil : 700, minHeight: embedded ? nil : 620)
        .onChange(of: statusModel.daemonServiceState) { _, state in
            if state != .running {
                showApplyNow = false
            }
        }
        .onChange(of: model.hasUnsavedChanges) { _, hasUnsavedChanges in
            if hasUnsavedChanges {
                showApplyNow = false
            }
        }
        .onChange(of: onboardingMode) { _, _ in
            onboardingMessage = nil
        }
        .onAppear {
            onboardingStorageMode = model.storageMode()
            if model.configExists && model.backupRoots.isEmpty {
                onboardingMode = .existingBackup
            }
        }
    }

    var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 10)
    }

    var settingsFooter: some View {
        let isAwaitingApply = showApplyNow && !model.hasUnsavedChanges

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
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

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button("Reload") {
                        model.load()
                        showApplyNow = false
                    }
                    .buttonStyle(.bordered)

                    if isAwaitingApply {
                        Button("Saved") {
                            model.save()
                            showApplyNow = model.shouldOfferApplyNow(daemonState: statusModel.daemonServiceState)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canSave)
                        .keyboardShortcut("s", modifiers: [.command])
                    } else {
                        Button("Save") {
                            model.save()
                            showApplyNow = model.shouldOfferApplyNow(daemonState: statusModel.daemonServiceState)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSave)
                        .keyboardShortcut("s", modifiers: [.command])
                    }
                }
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
                    .buttonStyle(.borderedProminent)
                    .disabled(statusModel.isLifecycleBusy)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var shouldShowOnboarding: Bool {
        !onboardingDismissed && (!model.configExists || model.backupRoots.isEmpty)
    }

    func completeOnboarding(runBackupNow: Bool) {
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

    func completeExistingBackupOnboarding() {
        let passphrase = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validation = model.existingBackupValidationMessage(passphrase: passphrase) {
            onboardingMessage = validation
            return
        }

        model.save()
        if let error = model.errorMessage {
            onboardingMessage = error
            return
        }

        Task {
            let connected = await statusModel.recoverExistingBackup(
                passphrase: passphrase,
                keychainService: model.keychainService,
                keychainAccount: model.keychainAccount
            )
            onboardingMessage = statusModel.recoveryMessage
            guard connected else {
                return
            }

            recoveryPassphrase = ""
            onboardingDismissed = true
            onRecoveryConnected?()
        }
    }
}
