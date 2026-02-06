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
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }

                            HStack {
                                Button("Add Folder...") {
                                    model.chooseBackupRoots()
                                }
                                Button("Remove All") {
                                    model.clearBackupRoots()
                                }
                                .disabled(model.backupRoots.isEmpty)
                                Spacer()
                                Picker("Schedule", selection: $model.schedule) {
                                    ForEach(BackupSchedule.allCases) { schedule in
                                        Text(schedule.rawValue.capitalized).tag(schedule)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }
                        }
                    }

                    SettingsCard(title: "S3", subtitle: "Leave bucket empty for local object storage.") {
                        VStack(spacing: 8) {
                            SettingRow(label: "Endpoint") {
                                TextField("https://s3.amazonaws.com (optional)", text: $model.s3Endpoint)
                            }
                            SettingRow(label: "Region") {
                                TextField("us-west-2", text: $model.s3Region)
                            }
                            SettingRow(label: "Bucket") {
                                TextField("my-backups", text: $model.s3Bucket)
                            }
                            SettingRow(label: "Prefix") {
                                TextField("baxter/", text: $model.s3Prefix)
                            }
                        }
                    }

                    SettingsCard(title: "Encryption", subtitle: "Keychain item used when BAXTER_PASSPHRASE is not set.") {
                        VStack(spacing: 8) {
                            SettingRow(label: "Service") {
                                TextField("baxter", text: $model.keychainService)
                            }
                            SettingRow(label: "Account") {
                                TextField("default", text: $model.keychainAccount)
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
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content
        }
    }
}
