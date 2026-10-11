import SwiftUI

enum BaxterSettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case schedule
    case storage
    case encryption
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .schedule:
            return "Schedule"
        case .storage:
            return "Storage"
        case .encryption:
            return "Encryption"
        case .notifications:
            return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .schedule:
            return "calendar.badge.clock"
        case .storage:
            return "externaldrive"
        case .encryption:
            return "lock"
        case .notifications:
            return "bell.badge"
        }
    }
}

struct BaxterSettingsView: View {
    enum OnboardingMode: String, CaseIterable, Identifiable {
        case newBackup
        case existingBackup

        var id: String { rawValue }
    }

    @ObservedObject var model: BaxterSettingsModel
    @ObservedObject var statusModel: BackupStatusModel
    var onRecoveryConnected: (() -> Void)? = nil
    @AppStorage("baxter.onboarding.dismissed") var onboardingDismissed = false
    @AppStorage("baxter.settings.selectedTab") var selectedTab: BaxterSettingsTab = .general
    @State var showApplyNow = false
    @State private var isOnboarding = false
    @State var selectedBackupRoots: Set<String> = []
    @State var onboardingMode: OnboardingMode = .newBackup
    @State var onboardingStorageMode: StorageModeOption = .local
    @State var recoveryPassphrase = ""
    @State var onboardingMessage: String?

    var body: some View {
        Group {
            if isOnboarding && !onboardingDismissed {
                onboardingPane
            } else {
                settingsTabs
            }
        }
        .frame(width: 620, height: 520)
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
        .onChange(of: model.backupRoots) { _, roots in
            selectedBackupRoots.formIntersection(roots)
        }
        .onChange(of: onboardingMode) { _, _ in
            onboardingMessage = nil
        }
        .onAppear {
            isOnboarding = shouldShowOnboarding
            onboardingStorageMode = model.storageMode()
            if model.configExists && model.backupRoots.isEmpty {
                onboardingMode = .existingBackup
            }
        }
    }

    private var settingsTabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(BaxterSettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    settingsPane(for: tab)
                }
            }
        }
    }

    private func settingsPane(for tab: BaxterSettingsTab) -> some View {
        Form {
            switch tab {
            case .general:
                generalSections
            case .schedule:
                scheduleSections
            case .storage:
                storageSections
            case .encryption:
                encryptionSections
            case .notifications:
                notificationsSections
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab != .notifications {
                settingsFooter
            }
        }
    }

    var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    settingsFooterStatus
                    Spacer(minLength: 12)
                    Button("Reload") {
                        model.load()
                        showApplyNow = false
                    }

                    Button("Save") {
                        model.save()
                        showApplyNow = model.shouldOfferApplyNow(daemonState: statusModel.daemonServiceState)
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
                }

                if showApplyNow {
                    HStack(spacing: 12) {
                        Text("Restart the daemon to apply the saved settings now.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Apply Now") {
                            statusModel.applyConfigNow()
                            showApplyNow = false
                        }
                        .disabled(statusModel.isLifecycleBusy)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var settingsFooterStatus: some View {
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let validationMessage = model.firstValidationError {
            Label(validationMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if model.hasUnsavedChanges {
            Text("Unsaved changes")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let statusMessage = model.statusMessage {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    func fieldError(_ field: SettingsField) -> some View {
        if let message = model.validationMessage(for: field) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
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
