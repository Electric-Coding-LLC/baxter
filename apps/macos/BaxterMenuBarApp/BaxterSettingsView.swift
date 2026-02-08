import SwiftUI

struct BaxterSettingsView: View {
    @ObservedObject var model: BaxterSettingsModel
    @ObservedObject var statusModel: BackupStatusModel
    @State private var showApplyNow = false
    @State private var restorePrefix = ""
    @State private var restoreContains = ""
    @State private var restorePath = ""
    @State private var restoreToDir = ""
    @State private var restoreOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Baxter Settings")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

                    SettingsCard(title: "Restore (Preview)", subtitle: "Find paths and preview restore destination without writing files.") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Filter prefix (optional)", text: $restorePrefix)
                                TextField("Contains text (optional)", text: $restoreContains)
                                Button("Search") {
                                    statusModel.fetchRestoreList(prefix: restorePrefix, contains: restoreContains)
                                }
                                .disabled(statusModel.isRestoreBusy)
                            }

                            if !statusModel.restorePaths.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(statusModel.restorePaths.prefix(8)), id: \.self) { path in
                                        Button(path) {
                                            restorePath = path
                                        }
                                        .buttonStyle(.plain)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if statusModel.restorePaths.count > 8 {
                                        Text("Showing first 8 of \(statusModel.restorePaths.count) paths.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }

                            TextField("Path to restore", text: $restorePath)
                                .font(.system(.body, design: .monospaced))
                            TextField("Destination root (optional)", text: $restoreToDir)
                            Toggle("Overwrite", isOn: $restoreOverwrite)
                                .font(.caption)

                            HStack {
                                Button("Dry Run Restore") {
                                    statusModel.previewRestore(path: restorePath, toDir: restoreToDir, overwrite: restoreOverwrite)
                                }
                                .disabled(statusModel.isRestoreBusy || restorePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                if statusModel.isRestoreBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if let message = statusModel.restorePreviewMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
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
        .padding()
        .frame(minWidth: 700, minHeight: 620)
        .onChange(of: statusModel.daemonServiceState) { _, state in
            if state != .running {
                showApplyNow = false
            }
        }
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
