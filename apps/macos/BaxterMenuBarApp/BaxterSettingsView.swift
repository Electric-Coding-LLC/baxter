import SwiftUI

struct BaxterSettingsView: View {
    @ObservedObject var model: BaxterSettingsModel

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
                                Spacer()
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
                }
                Button("Save") {
                    model.save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 620)
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
