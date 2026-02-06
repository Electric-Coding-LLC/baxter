import SwiftUI

struct BaxterSettingsView: View {
    @ObservedObject var model: BaxterSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Backup") {
                    Text("Backup roots (one path per line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $model.backupRootsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)

                    Picker("Schedule", selection: $model.schedule) {
                        ForEach(BackupSchedule.allCases) { schedule in
                            Text(schedule.rawValue.capitalized).tag(schedule)
                        }
                    }
                }

                Section("S3") {
                    TextField("Endpoint", text: $model.s3Endpoint)
                    TextField("Region", text: $model.s3Region)
                    TextField("Bucket", text: $model.s3Bucket)
                    TextField("Prefix", text: $model.s3Prefix)
                }

                Section("Encryption") {
                    TextField("Keychain Service", text: $model.keychainService)
                    TextField("Keychain Account", text: $model.keychainAccount)
                }
            }

            Text("Config path: \(model.configURL.path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Reload") {
                    model.load()
                }
                Button("Save") {
                    model.save()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 560)
    }
}
